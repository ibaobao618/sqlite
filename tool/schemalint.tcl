
set ::VERBOSE 0

proc usage {} {
  puts stderr "Usage: $::argv0 ?SWITCHES? DATABASE/SCHEMA"
  puts stderr "  Switches are:"
  puts stderr "  -select SQL     (recommend indexes for SQL statement)"
  puts stderr "  -verbose        (increase verbosity of output)"
  puts stderr "  -test           (run internal tests and then exit)"
  puts stderr ""
  exit
}

proc process_cmdline_args {ctxvar argv} {
  upvar $ctxvar G
  set nArg [llength $argv]
  set G(database) [lindex $argv end]

  for {set i 0} {$i < [llength $argv]-1} {incr i} {
    set k [lindex $argv $i]
    switch -- $k {
      -select {
        incr i
        if {$i>=[llength $argv]-1} usage
        lappend G(lSelect) [lindex $argv $i]
      }
      -verbose {
        set ::VERBOSE 1
      }
      -test {
        sqlidx_internal_tests
      }
      default {
        usage
      }
    }
  }

  if {$G(database)=="-test"} {
    sqlidx_internal_tests
  }
}

proc open_database {ctxvar} {
  upvar $ctxvar G
  sqlite3 db ""

  # Check if the "database" file is really an SQLite database. If so, copy
  # it into the temp db just opened. Otherwise, assume that it is an SQL
  # schema and execute it directly.
  set fd [open $G(database)]
  set hdr [read $fd 16]
  if {$hdr == "SQLite format 3\000"} {
    close $fd
    sqlite3 db2 $G(database)
    sqlite3_backup B db main db2 main
    B step 2000000000
    set rc [B finish]
    db2 close
    if {$rc != "SQLITE_OK"} { error "Failed to load database $G(database)" }
  } else {
    append hdr [read $fd]
    db eval $hdr
    close $fd
  }
}

proc analyze_selects {ctxvar} {
  upvar $ctxvar G
  set G(trace) ""

  # Collect a line of xTrace output for each loop in the set of SELECT
  # statements.
  proc xTrace {zMsg} { 
    upvar G G
    lappend G(trace) $zMsg 
  }
  db trace xTrace
  foreach s $G(lSelect) {
    set stmt [sqlite3_prepare_v2 db $s -1 dummy]
    set rc [sqlite3_finalize $stmt]
    if {$rc!="SQLITE_OK"} {
      error "Failed to compile SQL: [sqlite3_errmsg db]"
    }
  }

  db trace ""
  if {$::VERBOSE} {
    foreach t $G(trace) { puts "trace: $t" }
  }

  # puts $G(trace)
}

# The argument is a list of the form:
#
#    key1 {value1.1 value1.2} key2 {value2.1 value 2.2...}
#
# Values lists may be of any length greater than zero. This function returns
# a list of lists created by pivoting on each values list. i.e. a list
# consisting of the elements:
#
#   {{key1 value1.1} {key2 value2.1}}
#   {{key1 value1.2} {key2 value2.1}}
#   {{key1 value1.1} {key2 value2.2}}
#   {{key1 value1.2} {key2 value2.2}}
#
proc expand_eq_list {L} {
  set ll [list {}]
  for {set i 0} {$i < [llength $L]} {incr i 2} {
    set key [lindex $L $i]
    set new [list]
    foreach piv [lindex $L $i+1] {
      foreach l $ll {
        lappend new [concat $l [list [list $key $piv]]]
      }
    }
    set ll $new
  }

  return $ll
}

#--------------------------------------------------------------------------
# Formulate a CREATE INDEX statement that creates an index on table $tname.
#
proc eqset_to_index {ctxvar tname eqset {range {}}} {
  upvar $ctxvar G

  set lCols [list]
  set idxname $tname
  foreach e [lsort $eqset] { 
    if {[llength $e]==0} continue
    foreach {c collate} $e {}
    lappend lCols "$c collate $collate"
    append idxname "_$c"
    if {[string compare -nocase binary $collate]!=0} {
      append idxname [string tolower $collate]
    }
  }

  foreach {c collate dir} $range {
    append idxname "_$c"
    if {[string compare -nocase binary $collate]!=0} {
      append idxname [string tolower $collate]
    }
    if {$dir=="DESC"} {
      lappend lCols "$c collate $collate DESC"
      append idxname "desc"
    } else {
      lappend lCols "$c collate $collate"
    }
  }

  set create_index "CREATE INDEX $idxname ON ${tname}("
  append create_index [join $lCols ", "]
  append create_index ");"

  set G(trial.$idxname) $create_index
}

proc expand_or_cons {L} {
  set lRet [list [list]]
  foreach elem $L {
    set type [lindex $elem 0]
    if {$type=="eq" || $type=="range"} {
      set lNew [list]
      for {set i 0} {$i < [llength $lRet]} {incr i} {
        lappend lNew [concat [lindex $lRet $i] [list $elem]]
      }
      set lRet $lNew
    } elseif {$type=="or"} {
      set lNew [list]
      foreach branch [lrange $elem 1 end] {
        foreach b [expand_or_cons $branch] {
          for {set i 0} {$i < [llength $lRet]} {incr i} {
            lappend lNew [concat [lindex $lRet $i] $b]
          }
        }
      }
      set lRet $lNew
    } 
  }
  return $lRet
}

proc find_trial_indexes {ctxvar} {
  upvar $ctxvar G
  foreach t $G(trace) {
    set tname [lindex $t 0]
    catch { array unset mask }

    set orderby [list]
    if {[lindex $t end 0]=="orderby"} {
      set orderby [lrange [lindex $t end] 1 end]
    }

    foreach lCons [expand_or_cons [lrange $t 2 end]] {

      # Populate the array mask() so that it contains an entry for each
      # combination of prerequisite scans that may lead to distinct sets
      # of constraints being usable.
      #
      catch { array unset mask }
      set mask(0) 1
      foreach a $lCons {
        set type [lindex $a 0]
        if {$type=="eq" || $type=="range"} {
          set m [lindex $a 3]
          foreach k [array names mask] { set mask([expr ($k & $m)]) 1 }
          set mask($m) 1
        }
      }

      # Loop once for each distinct prerequisite scan mask identified in
      # the previous block.
      #
      foreach k [array names mask] {

        # Identify the constraints available for prerequisite mask $k. For
        # each == constraint, set an entry in the eq() array as follows:
        # 
        #   set eq(<col>) <collation>
        #
        # If there is more than one == constraint for a column, and they use
        # different collation sequences, <collation> is replaced with a list
        # of the possible collation sequences. For example, for:
        #
        #   SELECT * FROM t1 WHERE a=? COLLATE BINARY AND a=? COLLATE NOCASE
        #
        # Set the following entry in the eq() array:
        #
        #   set eq(a) {binary nocase}
        #
        # For each range constraint found an entry is appended to the $ranges
        # list. The entry is itself a list of the form {<col> <collation>}.
        #
        catch {array unset eq}
        set ranges [list]
        foreach a $lCons {
          set type [lindex $a 0]
          if {$type=="eq" || $type=="range"} {
            foreach {type col collate m} $a {
              if {($m & $k)==$m} {
                if {$type=="eq"} {
                  lappend eq($col) $collate
                } else {
                  lappend ranges [list $col $collate ASC]
                }
              }
            }
          }
        }
        set ranges [lsort -unique $ranges]
        if {$orderby != ""} {
          lappend ranges $orderby
        }

        foreach eqset [expand_eq_list [array get eq]] {
          if {$eqset != ""} {
            eqset_to_index G $tname $eqset
          }

          foreach r $ranges {
            set tail [list]
            foreach {c collate dir} $r {
              set bSeen 0
              foreach e $eqset {
                if {[lindex $e 0] == $c} {
                  set bSeen 1
                  break
                }
              }
              if {$bSeen==0} { lappend tail {*}$r }
            }
            if {[llength $tail]} {
              eqset_to_index G $tname $eqset $r
            }
          }
        }
      }
    }
  }

  if {$::VERBOSE} {
    foreach k [array names G trial.*] { puts "index: $G($k)" }
  }
}

proc run_trials {ctxvar} {
  upvar $ctxvar G
  set ret [list]

  foreach k [array names G trial.*] {
    set idxname [lindex [split $k .] 1]
    db eval $G($k)
    set pgno [db one {SELECT rootpage FROM sqlite_master WHERE name = $idxname}]
    set IDX($pgno) $idxname
  }
  db eval ANALYZE

  catch { array unset used }
  foreach s $G(lSelect) {
    db eval "EXPLAIN $s" x {
      if {($x(opcode)=="OpenRead" || $x(opcode)=="ReopenIdx")} {
        if {[info exists IDX($x(p2))]} { set used($IDX($x(p2))) 1 }
      }
    }
    foreach idx [array names used] {
      lappend ret $G(trial.$idx)
    }
  }

  set ret
}

proc sqlidx_init_context {varname} {
  upvar $varname G
  set G(lSelect)  [list]           ;# List of SELECT statements to analyze
  set G(database) ""               ;# Name of database or SQL schema file
  set G(trace)    [list]           ;# List of data from xTrace()
}

#-------------------------------------------------------------------------
# The following is test code only.
#
proc sqlidx_one_test {tn schema select expected} {
#  if {$tn!=2} return
  sqlidx_init_context C

  sqlite3 db ""
  db eval $schema
  lappend C(lSelect) $select
  analyze_selects C
  find_trial_indexes C

  set idxlist [run_trials C]
  if {$idxlist != [list {*}$expected]} {
    puts stderr "Test $tn failed"
    puts stderr "Expected: $expected"
    puts stderr "Got: $idxlist"
    exit -1
  }

  db close
}

proc sqlidx_internal_tests {} {

  # No indexes for a query with no constraints.
  sqlidx_one_test 0 {
    CREATE TABLE t1(a, b, c);
  } {
    SELECT * FROM t1;
  } {
  }

  sqlidx_one_test 1 {
    CREATE TABLE t1(a, b, c);
    CREATE TABLE t2(x, y, z);
  } {
    SELECT a FROM t1, t2 WHERE a=? AND x=c
  } {
    {CREATE INDEX t2_x ON t2(x collate BINARY);}
    {CREATE INDEX t1_a_c ON t1(a collate BINARY, c collate BINARY);}
  }

  sqlidx_one_test 2 {
    CREATE TABLE t1(a, b, c);
  } {
    SELECT * FROM t1 WHERE b>?;
  } {
    {CREATE INDEX t1_b ON t1(b collate BINARY);}
  }

  sqlidx_one_test 3 {
    CREATE TABLE t1(a, b, c);
  } {
    SELECT * FROM t1 WHERE b COLLATE nocase BETWEEN ? AND ?
  } {
    {CREATE INDEX t1_bnocase ON t1(b collate NOCASE);}
  }

  sqlidx_one_test 4 {
    CREATE TABLE t1(a, b, c);
  } {
    SELECT a FROM t1 ORDER BY b;
  } {
    {CREATE INDEX t1_b ON t1(b collate BINARY);}
  }

  sqlidx_one_test 5 {
    CREATE TABLE t1(a, b, c);
  } {
    SELECT a FROM t1 WHERE a=? ORDER BY b;
  } {
    {CREATE INDEX t1_a_b ON t1(a collate BINARY, b collate BINARY);}
  }

  sqlidx_one_test 5 {
    CREATE TABLE t1(a, b, c);
  } {
    SELECT min(a) FROM t1
  } {
    {CREATE INDEX t1_a ON t1(a collate BINARY);}
  }

  sqlidx_one_test 6 {
    CREATE TABLE t1(a, b, c);
  } {
    SELECT * FROM t1 ORDER BY a ASC, b COLLATE nocase DESC, c ASC;
  } {
    {CREATE INDEX t1_a_bnocasedesc_c ON t1(a collate BINARY, b collate NOCASE DESC, c collate BINARY);}
  }

  exit
}
# End of internal test code.
#-------------------------------------------------------------------------

sqlidx_init_context D
process_cmdline_args D $argv
open_database D
analyze_selects D
find_trial_indexes D
foreach idx [run_trials D] { puts $idx }

