#!/bin/bash
source ~/stackrc
DEBUG=true
CONNMON=true
CONNMON_PID=0
CONTROLLERS=$(nova list | grep control)
PBENCH=true
PBENCH_INTERVAL=2
SSH_OPTS="StrictHostKeyChecking no"
declare -A WORKERS
WORKERS["keystone"]="public_workers|admin_workers"
WORKERS["nova"]="metadata_workers|osapi_compute_workers|ec2_workers"
WORKERS["neutron"]="rpc_workers|api_workers"

declare -A TIMES
TIMES["keystone"]=5000
TIMES["nova"]=128

declare -A CONCURRENCY
CONCURRENCY["keystone"]="64 96 128 160 192 224 256"
CONCURRENCY["nova"]="32 64 128"

log()
{
    echo "[$(date)]: $*"
}

check_controllers()
{
 for IP in $(echo "$CONTROLLERS" | awk '{print $12}' | cut -d "=" -f 2); do
  # Number of cores?
  CORES=$(ssh -o "${SSH_OPTS}" heat-admin@$IP sudo cat /proc/cpuinfo | grep processor | wc -l)
  log Controller : $IP
  log Number of cores : $CORES
  log Service : Keystone
  log $(ssh -o "${SSH_OPTS}" heat-admin@$IP sudo cat /etc/keystone/keystone.conf | grep -vi "NONE" | grep -v "#" |grep -E ${WORKERS["keystone"]})
  log Service : Nova
  log $(ssh -o "${SSH_OPTS}" heat-admin@$IP sudo cat /etc/nova/nova.conf | grep -vi "NONE" | grep -v "#" |grep -E ${WORKERS["nova"]})
  log Service : Neutron
  log $(ssh -o "${SSH_OPTS}" heat-admin@$IP sudo cat /etc/neutron/neutron.conf | grep -vi "NONE" | grep -v "#" |grep -E ${WORKERS["neutron"]})
 done
}

update_workers()
{
 declare -A services
 services["keystone"]="/etc/keystone/keystone.conf"
 services["nova"]="/etc/nova/nova.conf"
 services["neutron"]="/etc/neutron/neutron.conf"

 if [ -z "$1" ] ; then
  echo "ERROR : Pass # of workers to use"
  exit 1
 else
  log Setting : $1 for number of workers
  wkr_count=$1
 fi
 if [ -z "$2" ] ; then
  echo "ERROR : Pass which service to update"
  echo "Usage : update_workers COUNT SERVICE"
  echo "Valid services : keystone, nova, neutron"
  exit 1
 else
  log Updating : $2
  osp_service=$2
 fi

 for IP in $(echo "$CONTROLLERS" | awk '{print $12}' | cut -d "=" -f 2); do
  for i in $(echo ${WORKERS[$osp_service]} | tr "|" "\n") ; do
     log Copying Config files to : $IP
     ssh -o "${SSH_OPTS}" heat-admin@$IP sudo cp ${services[$osp_service]} ${services[$osp_service]}-copy
     ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "sed -i -e \"s/^\(${i}\)\( \)*=\( \)*\([0-9]\)*/${i}=${wkr_count}/g\" ${services[$osp_service]}"
  done
 done

 if [ "${osp_service}" == "keystone" ]; then
  IP=`echo "$CONTROLLERS" | head -n 1 | awk '{print $12}' | cut -d "=" -f 2`
  ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "pcs resource unmanage openstack-keystone"
  for IP in $(echo "$CONTROLLERS" | awk '{print $12}' | cut -d "=" -f 2); do
   ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "systemctl restart openstack-keystone"
  done
  ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "pcs resource manage openstack-keystone"
 fi
 if [ "${osp_service}" == "nova" ]; then
  IP=`echo "$CONTROLLERS" | head -n 1 | awk '{print $12}' | cut -d "=" -f 2`
  ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "pcs resource unmanage openstack-nova-api"
  ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "pcs resource unmanage openstack-nova-conductor"
  ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "pcs resource unmanage openstack-nova-scheduler"
  for IP in $(echo "$CONTROLLERS" | awk '{print $12}' | cut -d "=" -f 2); do
   ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "systemctl restart openstack-nova-api"
   ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "systemctl restart openstack-nova-conductor"
   ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "systemctl restart openstack-nova-scheduler"
  done
  ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "pcs resource manage openstack-nova-api"
  ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "pcs resource manage openstack-nova-conductor"
  ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "pcs resource manage openstack-nova-scheduler"
 fi

 sleep 5 # Give things time to come up

 for IP in $(echo "$CONTROLLERS" | awk '{print $12}' | cut -d "=" -f 2); do
  log Validate number of workers
  keystone_num=$(ssh -o "${SSH_OPTS}" heat-admin@$IP sudo ps afx | grep "[Kk]eystone" | wc -l)
  nova_num=$(ssh -o "${SSH_OPTS}" heat-admin@$IP sudo ps afx | grep "[Nn]ova" | wc -l)
  log $IP : keystone : $keystone_num workers
  log $IP : nova : $nova_num workers
 # Keystone should be 2x for public and private + 1 for main process
 # Nova should be 2x + 2, for conductor,api and console+scheduler
 # Neutron ?
 done
}

run_rally()
{
 if [ -z "$1" ] ; then
  echo "ERROR : Pass which service to run rally tests against"
  echo "Usage : run_rally SERVICE TEST_PREFIX"
  echo "Valid services : keystone, nova, neutron"
  exit 1
 else
  echo "Benchmarking : $1"
  osp_service=$1
  fi
 if [ -z "$2" ] ; then
  echo "ERROR : Pass test_prefix to run rally tests"
  echo "Usage : run_rally SERVICE TEST_PREFIX"
  echo "Valid services : keystone, nova, neutron"
  exit 1
 else
  test_prefix=$2
 fi
 for task_file in `ls ${osp_service}`
 do
  if [ ${task_file: -3} == "-cc" ]
  then
   for concur in ${CONCURRENCY[${osp_service}]}
   do
    times=${TIMES[${osp_service}]}
    task_dir=$osp_service
    concur_padded="$(printf "%04d" ${concur})"
    test_name="${test_prefix}-${task_file}-${concur_padded}"
    log Test-Name ${test_name}
    sed -i "s/\"concurrency\": 1,/\"concurrency\": ${concur},/g" ${task_dir}/${task_file}
    sed -i "s/\"times\": 1,/\"times\": ${times},/g" ${task_dir}/${task_file}
    truncate_token_bloat
    if $CONNMON ; then
        log Starting connmon
        connmond --config connmon/config > connmond-${test_name} 2>&1 &
        CONNMON_PID=$!
    fi

    if $PBENCH ; then
     setup_pbench
     user-benchmark --config=${test_name} -- "./browbeat-run-rally.sh ${task_dir}/${task_file} ${test_name}"
    else
     # pbench is off, just run rally directly
     rally task start --task ${task_dir}/${task_file} 2>&1 | tee ${test_name}.log
    fi

    if $CONNMON ; then
        log Stopping connmon
        kill -9 $CONNMON_PID
        mv current-run.csv ${test_name}
    fi

    # grep the log file for the results to be run
    test_id=`grep "rally task results" ${test_name}.log | awk '{print $4}'`
    rally task report ${test_id} --out ${test_name}.html
    if $PBENCH ; then
     pbench_results_dir=`find /var/lib/pbench-agent/ -name "*${test_prefix}*" -print`
     log "Copying rally report and log into ${pbench_results_dir}"
     cp ${test_name}.log ${pbench_results_dir}
     cp ${test_name}.html ${pbench_results_dir}
     move-results --prefix=${test_prefix}/${task_file}-${concur}
     clear-tools
    fi
    mv ${test_name}.log results/
    mv ${test_name}.html results/

    sed -i "s/\"concurrency\": ${concur},/\"concurrency\": 1,/g" ${task_dir}/${task_file}
    sed -i "s/\"times\": ${times},/\"times\": 1,/g" ${task_dir}/${task_file}
   done
  fi
 done
}

setup_pbench()
{
 log "Setting up pbench tools"
 clear-tools
 kill-tools
 sudo /opt/pbench-agent/util-scripts/register-tool --name=mpstat -- --interval=${PBENCH_INTERVAL}
 sudo /opt/pbench-agent/util-scripts/register-tool --name=iostat -- --interval=${PBENCH_INTERVAL}
 sudo /opt/pbench-agent/util-scripts/register-tool --name=sar -- --interval=${PBENCH_INTERVAL}
 sudo /opt/pbench-agent/util-scripts/register-tool --name=vmstat -- --interval=${PBENCH_INTERVAL}
 sudo /opt/pbench-agent/util-scripts/register-tool --name=pidstat -- --interval=${PBENCH_INTERVAL}
 for IP in $(echo "$CONTROLLERS" | awk '{print $12}' | cut -d "=" -f 2); do
  register-tool --name=mpstat --remote=${IP} -- --interval=${PBENCH_INTERVAL}
  register-tool --name=iostat --remote=${IP} -- --interval=${PBENCH_INTERVAL}
  register-tool --name=sar --remote=${IP} -- --interval=${PBENCH_INTERVAL}
  register-tool --name=vmstat --remote=${IP} -- --interval=${PBENCH_INTERVAL}
  register-tool --name=pidstat --remote=${IP} -- --interval=${PBENCH_INTERVAL}
 done
}

truncate_token_bloat()
{
 log "Truncating Token Bloat"
 IP=`echo "$CONTROLLERS" | head -n 1 | awk '{print $12}' | cut -d "=" -f 2`
 ssh -o "${SSH_OPTS}" heat-admin@$IP sudo "mysql keystone -e 'truncate token;'"
}


if [ ! $# == 1 ]; then
  echo "Usage: ./browbeat.sh <test_prefix>"
  exit
fi
complete_test_prefix=$1

if $DEBUG ; then
  log $CONTROLLERS
fi

#
# 1) Show the current # of workers
# 2) Run Tests (Keystone, Nova, Neutron)
# 3) Update # of workers per-service
# 4) Re-Run tests above
#

mkdir -p results
check_controllers
for num_wkrs in `seq 24 -4 4`; do
  num_wkr_padded="$(printf "%02d" ${num_wkrs})"

  update_workers ${num_wkrs} keystone
  check_controllers
  run_rally keystone "${complete_test_prefix}-keystone-${num_wkr_padded}"

  update_workers ${num_wkrs} nova
  check_controllers
  run_rally nova "${complete_test_prefix}-nova-${num_wkr_padded}"

done
update_workers 24 keystone
update_workers 24 nova
check_controllers