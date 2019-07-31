#!/bin/bash


cd "$(dirname "$0")"

# config variable
sys_refs_yaml_template=sys-refs-template.yaml
sys_refs_yaml=sys-refs.yaml
sys_refs=sys-refs/sys-refs
perf=pmutools/ocperf.py
sys_refs_runtime=600

# parameter variable
target_pid=
dram_percent=25
hot_node=
cold_node=
run_time=1200

# runtime variable
sys_refs_pid=
perf_pid=
sys_refs_log=
perf_log=


# parser
perf_ipc_parser=./perf_parser_ipc.rb
perf_bw_parser=./perf_parser_bw.rb
sysrefs_ratio_parser=./sysrefs_parser_ratio.rb

usage() {
    echo "usage: $0:"
    echo "       -p target PID."
    echo "       -d dram percent for target PID."
    echo "       -h NUMA node id for HOT pages."
    echo "       -c NUMA node id for COLD pages."
    echo "       -t Run time, in second unit."
    echo "For example:"
    echo "the target pid is 100, we want to leave 25% hot pages to NUMA node 1,"
    echo "leave remain cold pages to NUMA node 3, run total 20 minutes:"
    echo "$0 -p 100 -d 25 -h 1 -c 3 -t 1200"
}

parse_parameter() {
    while getopts ":p:d:h:c:t:" optname; do
        case "$optname" in
            "p")
                # echo "-p $OPTARG"
                target_pid=$OPTARG
                ;;
            "d")
                # echo "-d $OPTARG"
                dram_percent=$OPTARG
                ;;
            "h")
                # echo "-h $OPTARG"
                hot_node=$OPTARG
                ;;
            "c")
                # echo "-c $OPTARG"
                cold_node=$OPTARG
                ;;
            "t")
                # echo "-t $OPTARG"
                run_time=$OPTARG
                ;;
            ":")
                echo "no value for option $OPTARG"
                ;;
            "?")
                echo "WARNING: Ingore the unknow parameters"
                ;;
        esac
    done
}

check_parameter() {
    local will_exit=0

    if [[ -z $hot_node ]]; then
        echo "Please use -h to indicate NUMA node for HOT pages"
        will_exit=1
    fi

    if [[ -z $cold_node ]]; then
        echo "Please use -c to indicate NUMA node for COLD pages"
        will_exit=1
    fi

    if [[ -z $target_pid ]]; then
        echo "Please use -p to indicate target PID"
        will_exit=1
    fi

    if [[ $will_exit -eq 1 ]]; then
        usage
        exit 1
    fi

    echo "parameter dump:"
    echo "  target PID = $target_pid"
    echo "  DRAM percent = $dram_percent"
    echo "  time = $run_time"
    echo "  hot node = $hot_node"
    echo "  cold node = $cold_node"

    sys_refs_log=sys-refs-$target_pid-$dram_percent.log
    perf_log=perf-$target_pid-$dram_percent.log
}

prepare_sys_refs() {
    local pid=$1
    if  [[ ! -e $sys_refs_yaml_template ]]; then
        echo "Error: No $sys_refs_yaml_template file"
        exit 10
    fi

    cat $sys_refs_yaml_template > $sys_refs_yaml

    # NUMA part
    cat >> $sys_refs_yaml <<EOF
  numa_nodes:
    $hot_node:
      type: DRAM
      demote_to: $cold_node
    $cold_node:
      type: PMEM
      demote_to: $hot_node
EOF
    # policy part
    cat >> $sys_refs_yaml <<EOF

policies:
  - pid: $pid
    dump_distribution: true

EOF
}

run_sys_refs() {
    echo "sys_refs_log: $sys_refs_log"
    stdbuf -oL $sys_refs -d $dram_percent -c $sys_refs_yaml > $sys_refs_log 2>&1 &
    sys_refs_pid=$(pidof sys-refs)
    echo "sys-refs pid: $sys_refs_pid"
}

run_perf() {
    local perf_cmd="$perf stat -p $target_pid -o $perf_log "
    local perf_cmd_end=" -- sleep $run_time"
    local perf_event=(
        # SLX only, test only
        cpu/event=0xbb,umask=0x1,offcore_rsp=0x7bc0007f5,name=total_read/
        cpu/event=0xbb,umask=0x1,offcore_rsp=0x7b80007f5,name=remote_read_COLD/
        cpu/event=0xbb,umask=0x1,offcore_rsp=0x7840007f5,name=local_read_HOT/
    )

    #TODO: perf list to set right event in perf_event

    for i in ${perf_event[@]}; do
        perf_cmd="$perf_cmd -e $i "
    done
    perf_cmd="$perf_cmd $perf_cmd_end"
    echo perf_log: $perf_log
    $perf_cmd
}

parse_perf_log() {
    if [[ ! -f $perf_log ]]; then
        echo "ERROR: No $perf_log file"
        exit -1
    fi

    cat $perf_log
    $perf_bw_parser < $perf_log
}

parse_sys_refs_log() {

    if [[ ! -f $sys_refs_log ]]; then
        return 0;
    fi

    echo ""
    $sysrefs_ratio_parser < $sys_refs_log
}

cpu_to_node() {
    local cpu=cpu$1
    local node_path=$(echo /sys/bus/cpu/devices/$cpu/node*)

    if [[ -d $node_path ]]; then
        return ${node_path#*/node}
    fi

    echo "ERROR: failed get NODE id for $cpu"
    exit -1
}

hardware_detect() {
    local running_cpu=

    # skip if user provided -h or -c
    if [[ ! -z $hot_node ]]; then
        return 0
    fi
    if [[ ! -z $cold_node ]]; then
        return 0
    fi

    running_cpu=$(ps -o psr $target_pid | tail -n +2)
    cpu_to_node $running_cpu
    hot_node=$?
    cold_node=$(($hot_node^1))

    # Consider to reduce dependency, we consider to rewrite below
    # rb by python.
    #│The more sophisticated solution is to use top node as COLD and 2nd
    #│large node as HOT, based on smaps stats:
    #│
    #│       % ./task-numa-maps.rb $$
    #│       N0  6M  99%
    #│       N4  0M  0%
    #│       N8  0M  0%
    #│
    #│But if user specified the values, just leave it to user.
    echo "PID $target_pid running on node $hot_node. HOT node:$hot_node COLD node:$cold_node.";
}

wait_pid_timeout()
{
    local wait_pid=$1
    local timeout=$2

    if [[ -z $wait_pid ]]; then
        return 0
    fi

    # no timeout ? so let's keep wattting.
    if [[ -z $timeout ]]; then
        wait $wait_pid
        return 0
    fi

    for i in $(seq 1 $timeout); do
        if [[ ! -d /proc/$wait_pid ]]; then
            break
        fi
        sleep 1
        printf "\rWaitting for $wait_pid ($i/$timeout seconds)"
    done
    printf "\n"
    return 0
}

kill_sys_refs()
{
    if [[ ! -z $sys_refs_pid ]]; then
        echo "killing sys_refs($sys_refs_pid)"
        kill $sys_refs_pid > /dev/null 2>&1
        sys_refs_pid=
    fi
}

kill_perf()
{
    if [[ ! -z $perf_pid ]]; then
        echo "killing perf($perf_pid)"
        kill $perf_pid > /dev/null 2>&1
        perf_pid=
    fi
}

run_perf_ipc()
{       
    local ipc_runtime=$1
    local perf_log_ipc=perf-$target_pid-$dram_percent-ipc.log
    local perf_cmd="$perf stat -p $target_pid \
                    -e cycles,instructions \
                    -o $perf_log_ipc -- sleep $ipc_runtime"
    
    $perf_cmd > $perf_log_ipc 2>&1

    echo $($perf_ipc_parser < $perf_log_ipc)
}

output_perf_ipc()
{
    echo ""
    echo "IPC baseline:        $perf_ipc_before"
    echo "IPC after migration: $perf_ipc_after"
}

on_ctrlc()
{
    echo "Ctrl-C received"
    kill_sys_refs
    kill_perf
}

trap 'on_ctrlc' INT

parse_parameter "$@"
hardware_detect
check_parameter

echo "Gathering basline IPC data (60 seconds)"
perf_ipc_before=$(run_perf_ipc 60)

prepare_sys_refs $target_pid
run_sys_refs

wait_pid_timeout $sys_refs_pid $sys_refs_runtime

kill_sys_refs
run_perf

echo "Gathering IPC data (60 seconds)"
perf_ipc_after=$(run_perf_ipc 60)

parse_perf_log
parse_sys_refs_log
output_perf_ipc

kill_perf