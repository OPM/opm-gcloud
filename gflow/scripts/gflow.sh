#!/bin/bash  

# Copyright 2017 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the Li

sshparams="-i ~/.ssh/google_compute_engine"
mysdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

myproject=$(gcloud config get-va/lue project 2>/dev/null)
myuserid=$(gcloud config get-value account |sed -e 's/@/_/g'|sed -e 's/\./_/g')

function make_slurm_script() {
    cat > ${jobdir}/${jobname}/${jobname}.sh <<EOF 
#!/bin/bash
#
# This is overridden by command line script. 
#SBATCH --job-name=${jobname}
#SBATCH --output=joblog.${jobname}.jobid.%j.log
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=${ntask_per_node}

date
pwd

# make sure we have MPI and FLOW in our path
module load mpi

# we assume we only run on s ingle node.  No MPI across node. 
# run in parallel with MPI
mpirun -np \${SLURM_NTASKS_PER_NODE} flow ../${inputfile} --output-dir=output

date
EOF
}

function chk_fix_ssh () {
  if [ ! -f "$HOME/.gflow_keys_generated" ]; then
    ssh ${sshparams} ${myuserid}@${lgnode} "ls ~/.ssh/id_rsa" > /dev/null 2>&1
    if [ $? -ne 0 ]
    then
        #no ssh keys so lets generate them, add auth keys,generate config file so we don't ask to add hosts
        ssh ${sshparams} ${myuserid}@${lgnode} "ssh-keygen -t rsa -f ~/.ssh/id_rsa -N '' && cat ~/.ssh/id_rsa.pub > ~/.ssh/authorized_keys && echo 'StrictHostKeyChecking no' > ~/.ssh/config"
    else
	echo 1 >  ~/.gflow_keys_generated
    fi
  fi
}


if [ ! -f "${mysdir}/gflow_params.sh" ]; then
    lgnode=$(gcloud --project=${myproject} compute instances list --filter name=gflow-01-login1 --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

    echo "lgnode=${lgnode}" > ${mysdir}/gflow_params.sh
    . ${mysdir}/gflow_params.sh
    # fix ssh keys this one intial time. 
else
    # if the gflow_params.sh file exist it measn we took care of ssh keys.
    . ${mysdir}/gflow_params.sh
fi

chk_fix_ssh

function chk_fix_jobdir () {
# chekc if jobdir exits
if [ ! -d "${jobdir}" ]; then
    echo " ${jobdir} does not exit."
    exit
else    
    if [ -d "${jobdir}/${jobname}" ]; then
        echo "${jobdir}/${jobname} directory exits please remove it. "
        exit
    else
        mkdir ${jobdir}/${jobname}
    fi
fi
}

cmd=$1
case ${cmd} in 
    mkscript)
        if [ "$#" -ne 5 ]; then
            echo "I need the local directory: gflow mk_sub_script  <localdir>  <ntasks-per-node>  <jobname> <inputfile>"
            exit
        fi
        # default to --nodes=1 for now, get ldir path and strip out trailing /
        jobdir=${2%/}
        ntask_per_node=${3}
        jobname=${4}
        inputfile=${5}

        chk_fix_jobdir
        make_slurm_script
        ;;  
    put)
        if [ "$#" -ne 2 ]; then
            echo "I need the local directory: gflow put <localdir>"
            exit
        fi
        # get ldir path and strip out trailing /
        ldir=${2%/}
        echo "uploading: ${ldir}"
        #copy remote dir to GCP
        rsync -e "ssh ${sshparams}" -az --info=progress2 ${ldir} ${myuserid}@${lgnode}:~/
        ;;
    sub)
        if [ "$#" -ne 2 ]; then
            echo "<remote dir> is relative to \$HOME.(\$HOME/<remote dir>)"
            echo "I need the remote path to run and a job name:"
            echo "gflow sub <remotedir>/scriptname "
            exit
        fi
        # get ldir path and strip out trailing /
        rspath=${2#/}
        echo "submitting: ${rspath}"
        rpath=${2%/*} 
        # submit remote script
        ssh ${sshparams} ${myuserid}@${lgnode} "cd ~/${rpath}; sbatch ~/${rspath}"
        ;;
    stat)
        # submit remote script
        ssh ${sshparams} ${myuserid}@${lgnode} "squeue -o '%.7i %.9P %.28j %.8u %.2t %.10M %.6D %R' "
        ;;
    sstat)
        mjobid=" "
        if [ "$#" -eq 2 ]; then
            mjobid="-j ${2}"
        fi
        ssh ${sshparams}  ${myuserid}@${lgnode} "sstat --format=AveCPU,AvePages,AveRSS,AveVMSize,JobID --allsteps ${mjobid}"
        ;;
    tailfile)
        if [ "$#" -ne 2 ]; then
            echo "You must provide a job ID"
            exit
        else
            ssh ${sshparams}  ${myuserid}@${lgnode} "scontrol show job ${2} |grep -i stdout|awk -F'=' '{print \$2}' |xargs tail"
        fi
        ;;
    cancel)
        if [ "$#" -ne 2 ]; then
            echo "You must provide a job ID"
            exit
        else
            ssh ${sshparams}  ${myuserid}@${lgnode} "scancel ${2} "
        fi
        ;;
    get)
        if [ "$#" -ne 3 ]; then
            echo "I need the remote and local directories: gflow get <remotedir> <localdir>"
            exit
        fi
        # get ldir path and strip out trailing /
        rdir=${2}
        ldir=${3}
        echo "downloading: ${rdir} to ${ldir}"
        #copy remote dir to GCP
        rsync -e "ssh ${sshparams}" -az --info=progress2 ${myuserid}@${lgnode}:~/${rdir} ${ldir}
        ;;
    *)
        echo "Avaliable commads are"
        echo "<remote dir> is relative to \$HOME.(\$HOME/<remote dir>)"
        echo "gflow mkscript <local dir> <ntasks-per-node> <jobname> <inputfile>"
        echo "gflow put <local dir>"
        echo "gflow sub <remote dir>/<script>"
        echo "gflow stat "
        echo "gflow sstat <jobid>"
        echo "gflow cancel <jobid>"
        echo "gflow tailfile <jobid>"
        echo "gflow get <remote dir> <local dir>"
        ;;
esac
