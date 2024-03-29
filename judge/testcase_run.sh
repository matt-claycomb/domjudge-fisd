#!/bin/sh

# Script to test (run and compare) submissions with a single testcase
#
# Usage: $0 <testdata.in> <testdata.out> <timelimit> <workdir>
#           <run> <compare>
#
# <testdata.in>     File containing test-input with absolute pathname.
# <testdata.out>    File containing test-output with absolute pathname.
# <timelimit>       Timelimit in seconds, optionally followed by ':' and
#                   the hard limit to kill still running submissions.
# <workdir>         Directory where to execute submission in a chroot-ed
#                   environment. For best security leave it as empty as possible.
#                   Certainly do not place output-files there!
# <filename>        Name for file containing input data.
# <run>             Absolute path to run script to use.
# <compare>         Absolute path to compare script to use.
# <compare-args>    Arguments to path to compare script
#
# Default run and compare scripts can be configured in the database.
#
# Exit automatically, whenever a simple command fails and trap it:
set -e
trap 'cleanup ; error' EXIT

cleanup ()
{
	# Remove some copied files to save disk space
	if [ "$WORKDIR" ]; then
		# This assumes that if bin is bind-mounted from the chroot,
		# then it is read-only so the removal of bin/sh will fail.
		rm -f "$WORKDIR/../dev/null" "$WORKDIR/../bin/sh" "$WORKDIR/../dj-bin/runpipe" 2> /dev/null || true

		# Replace testdata by symlinks to reduce disk usage
		if [ -f "$WORKDIR/testdata.in" ]; then
			rm -f "$WORKDIR/testdata.in"
			ln -s "$TESTIN" "$WORKDIR/testdata.in"
		fi
		if [ -f "$WORKDIR/testdata.out" ]; then
			rm -f "$WORKDIR/testdata.out"
			ln -s "$TESTOUT" "$WORKDIR/testdata.out"
		fi
	fi

	# Copy runguard and program stderr to system output. The display is
	# truncated to normal size in the jury web interface.
	if [ -s runguard.err ]; then
		echo  "********** runguard stderr follows **********" >> system.out
		cat runguard.err >> system.out
	fi
}

cleanexit ()
{
	set +e
	trap - EXIT

	cleanup

	logmsg $LOG_DEBUG "exiting with status '$1'"
	exit $1
}

# Runs command without error trapping and check exitcode
runcheck ()
{
	logmsg $LOG_DEBUG "runcheck: $*"
	set +e
	"$@"
	exitcode=$?
	set -e
}

# Error and logging functions
# shellcheck disable=SC1090
. "$DJ_LIBDIR/lib.error.sh"


CPUSET=""
CPUSET_OPT=""
# Do argument parsing
OPTIND=1 # reset if necessary
while getopts "n:" opt; do
	case $opt in
		n)
			CPUSET="$OPTARG"
			;;
		:)
			echo "Option -$OPTARG requires an argument." >&2
			;;
	esac
done
# Shift any of the arguments out of the way
shift $((OPTIND-1))
[ "$1" = "--" ] && shift

if [ -n "$CPUSET" ]; then
	CPUSET_OPT="-P $CPUSET"
	LOGFILE="$DJ_LOGDIR/judge.$(hostname | cut -d . -f 1)-$CPUSET.log"
else
	LOGFILE="$DJ_LOGDIR/judge.$(hostname | cut -d . -f 1).log"
fi

# Logging:
LOGLEVEL=$LOG_DEBUG
PROGNAME="$(basename "$0")"

# Check for judge backend debugging:
if [ "$DEBUG" ]; then
	export VERBOSE=$LOG_DEBUG
	logmsg $LOG_NOTICE "debugging enabled, DEBUG='$DEBUG'"
else
	export VERBOSE=$LOG_ERR
fi

# Location of scripts/programs:
SCRIPTDIR="$DJ_LIBJUDGEDIR"
STATICSHELL="$DJ_LIBJUDGEDIR/sh-static"
GAINROOT="sudo -n"
RUNGUARD="$DJ_BINDIR/runguard"
RUNPIPE="$DJ_BINDIR/runpipe"
PROGRAM="execdir/program"

logmsg $LOG_INFO "starting '$0', PID = $$"

[ $# -ge 4 ] || error "not enough arguments. See script-code for usage."
TESTIN="$1";    shift
TESTOUT="$1";   shift
TIMELIMIT="$1"; shift
WORKDIR="$1";   shift
FILENAME="$1";  shift
RUN_SCRIPT="$1";
COMPARE_SCRIPT="$2";
COMPARE_ARGS="$3";
logmsg $LOG_DEBUG "arguments: '$TESTIN' '$TESTOUT' '$TIMELIMIT' '$WORKDIR' '$FILENAME'"
logmsg $LOG_DEBUG "optionals: '$RUN_SCRIPT' '$COMPARE_SCRIPT' '$COMPARE_ARGS'"

# optional runjury program
RUN_JURYPROG="${RUN_SCRIPT}jury"
logmsg $LOG_DEBUG "run_juryprog: '$RUN_JURYPROG'"

[ -r "$TESTIN"  ] || error "test-input not found: $TESTIN"
[ -r "$TESTOUT" ] || error "test-output not found: $TESTOUT"
if [ ! -d "$WORKDIR" ] || [ ! -w "$WORKDIR" ] || [ ! -x "$WORKDIR" ]; then
	error "Workdir not found or not writable: $WORKDIR"
fi
[ -x "$WORKDIR/$PROGRAM" ] || error "submission program not found or not executable"
[ -x "$COMPARE_SCRIPT" ] || error "compare script not found or not executable: $COMPARE_SCRIPT"
[ -x "$RUN_SCRIPT" ] || error "run script not found or not executable: $RUN_SCRIPT"
[ -x "$RUNGUARD" ] || error "runguard not found or not executable: $RUNGUARD"

cd "$WORKDIR"

# Check whether we're going to run in a chroot environment:
if [ -z "$USE_CHROOT" ] || [ "$USE_CHROOT" -eq 0 ]; then
# unset to allow shell default parameter substitution on USE_CHROOT:
	unset USE_CHROOT
	PREFIX=$PWD
else
	PREFIX="/$(basename "$PWD")"
fi

# Make testing/execute dir accessible for RUNUSER:
chmod a+x "$WORKDIR" "$WORKDIR/execdir"

# Create files which are expected to exist:
touch system.out                 # Judging system output (info/debug/error)
touch program.out program.err    # Program output and stderr (for extra information)
touch program.meta runguard.err  # Metadata and runguard stderr
touch compare.meta compare.err   # Compare runguard metadata and stderr

logmsg $LOG_INFO "setting up testing (chroot) environment"

# Copy the testdata input
cp "$TESTIN" "$WORKDIR/testdata.in"

# shellcheck disable=SC2174
mkdir -p -m 0711 ../bin ../dj-bin ../dev
# Copy the run-script and a statically compiled shell:
cp -p  "$RUN_SCRIPT"  ./run
chmod a+rx run
if [ ! -x ../bin/sh ]; then
	cp -pL "$STATICSHELL" ../bin/sh || true
	chmod a+rx ../bin/sh || true
fi
# If using a custom runjury script, copy additional support programs
# if required:
if [ -x "$RUN_JURYPROG" ]; then
	cp -p "$RUN_JURYPROG" ./runjury
	cp -pL "$RUNPIPE"     ../dj-bin/runpipe
	chmod a+rx runjury ../dj-bin/runpipe
fi

# We copy /dev/null: mknod (and the major/minor device numbers) are
# not portable, while a fifo link has the problem that a cat program
# must be run and killed.
logmsg $LOG_DEBUG "creating /dev/null character-special device"
$GAINROOT cp -pR /dev/null ../dev/null

# Run the solution program (within a restricted environment):
logmsg $LOG_INFO "running program (USE_CHROOT = ${USE_CHROOT:-0})"

INDATA="testdata.in"

if [ "$FILENAME" != "NULL" -a "$FILENAME" != "none" ]
then
  DIR=`dirname "$PREFIX/$PROGRAM"`
  cp testdata.in "$DIR/$FILENAME"
  cp testdata.in "$FILENAME"
  INDATA="/dev/null"
fi

# To suppress false positive of FILELIMIT misspelling of TIMELIMIT:
# shellcheck disable=SC2153
runcheck ./run "$INDATA" program.out \
	$GAINROOT "$RUNGUARD" ${DEBUG:+-v} $CPUSET_OPT \
	${USE_CHROOT:+-r "$PWD/.."} \
	--nproc=$PROCLIMIT \
	--no-core --streamsize=$FILELIMIT \
	--user="$RUNUSER" --group="$RUNGROUP" \
	--walltime=$TIMELIMIT --cputime=$TIMELIMIT \
	--memsize=$MEMLIMIT --filesize=$FILELIMIT \
	--stderr=program.err --outmeta=program.meta -- \
	"$PREFIX/$PROGRAM" 2>runguard.err

# Check for still running processes:
output=$(ps -u "$RUNUSER" -o pid= -o comm= || true)
if [ -n "$output" ] ; then
	error "found processes still running as '$RUNUSER', check manually:\n$output"
fi

# We first compare the output, so that even if the submission gets a
# timelimit exceeded or runtime error verdict later, the jury can
# still view the diff with what the submission produced.
logmsg $LOG_INFO "comparing output"

# Copy testdata output, only after program has run
cp "$TESTOUT" "$WORKDIR/testdata.out"

logmsg $LOG_DEBUG "starting compare script '$COMPARE_SCRIPT'"

exitcode=0
# Create dir for feedback files and make it writable for $RUNUSER
mkdir feedback
chmod a+w feedback

runcheck $GAINROOT "$RUNGUARD" ${DEBUG:+-v} $CPUSET_OPT -u "$RUNUSER" -g "$RUNGROUP" \
	-m $SCRIPTMEMLIMIT -t $SCRIPTTIMELIMIT -c \
	-f $SCRIPTFILELIMIT -s $SCRIPTFILELIMIT -M compare.meta -- \
	"$COMPARE_SCRIPT" testdata.in testdata.out feedback/ $COMPARE_ARGS < program.out \
	                  >compare.tmp 2>&1

# Make sure that feedback file exists, since we assume this later.
if [ ! -f feedback/judgemessage.txt ]; then
	touch feedback/judgemessage.txt
fi

# Append output validator error messages
# TODO: display extra
if [ -s feedback/judgeerror.txt ]; then
	printf "\n---------- output validator (error) messages ----------\n" >> feedback/judgemessage.txt
	cat feedback/judgeerror.txt >> feedback/judgemessage.txt
fi

logmsg $LOG_DEBUG "checking compare script exit-status: $exitcode"
if grep '^time-result: .*timelimit' compare.meta >/dev/null 2>&1 ; then
	logmsg $LOG_ERR "Comparing aborted after $SCRIPTTIMELIMIT seconds, compare script output:\n$(cat compare.tmp)"
	cleanexit ${E_COMPARE_ERROR:-1}
fi
# Append output validator stdin/stderr - display extra?
if [ -s compare.tmp ]; then
	printf "\n---------- output validator stdout/stderr messages ----------\n" >> feedback/judgemessage.txt
	cat compare.tmp >> feedback/judgemessage.txt
fi
if [ $exitcode -ne 42 ] && [ $exitcode -ne 43 ]; then
	logmsg $LOG_ERR "Comparing failed with exitcode $exitcode, compare script output:\n$(cat compare.tmp)"
	cleanexit ${E_COMPARE_ERROR:-1}
fi

# Check for errors from running the program:
if [ ! -r program.meta ]; then
	error "'program.meta' not readable"
fi
logmsg $LOG_DEBUG "checking program run exit-status"
# There's no bash YAML parser, and the format is rigid enough that we
# can parse it with grep here.
timeused=$(        grep '^time-used: '    program.meta | sed 's/time-used: //')
program_cputime=$( grep '^cpu-time: '     program.meta | sed 's/cpu-time: //')
program_walltime=$(grep '^wall-time: '    program.meta | sed 's/wall-time: //')
program_exit=$(    grep '^exitcode: '     program.meta | sed 's/exitcode: //')
program_stdout=$(  grep '^stdout-bytes: ' program.meta | sed 's/stdout-bytes: //')
program_stderr=$(  grep '^stderr-bytes: ' program.meta | sed 's/stderr-bytes: //')
memory_bytes=$(    grep '^memory-bytes: ' program.meta | sed 's/memory-bytes: //')
resourceinfo="\
runtime: ${program_cputime}s cpu, ${program_walltime}s wall
memory used: ${memory_bytes} bytes"
if grep '^time-result: .*timelimit' program.meta >/dev/null 2>&1 ; then
	echo "Timelimit exceeded." >>system.out
	echo "$resourceinfo" >>system.out
	cleanexit ${E_TIMELIMIT:-1}
fi
if [ "$program_exit" != "0" ]; then
	echo "Non-zero exitcode $program_exit" >>system.out
	echo "$resourceinfo" >>system.out
	cleanexit ${E_RUN_ERROR:-1}
fi

if grep -E '^output-truncated: ([a-z]+,)*stdout(,[a-z]+)*' program.meta >/dev/null 2>&1 ; then
	echo "Output limit exceeded: $program_stdout > $((FILELIMIT*1024))" >>system.out
	echo "$resourceinfo" >>system.out
	cleanexit ${E_OUTPUT_LIMIT:-1}
fi

if [ $exitcode -eq 42 ]; then
	echo "Correct!" >>system.out
	echo "$resourceinfo" >>system.out
	cleanexit ${E_CORRECT:-1}
elif [ $exitcode -eq 43 ]; then
	# Special case detect no-output:
	if [ ! -s program.out ];  then
		echo "Program produced no output." >>system.out
		echo "$resourceinfo" >>system.out
		cleanexit ${E_NO_OUTPUT:-1}
	fi
	echo "Wrong answer." >>system.out
	echo "$resourceinfo" >>system.out
	cleanexit ${E_WRONG_ANSWER:-1}
fi

# This should never be reached
exit ${E_INTERNAL_ERROR:-1}
