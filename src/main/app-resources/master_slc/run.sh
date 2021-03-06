#!/bin/bash
mode=$1
set -x

export PATH=${_CIOP_APPLICATION_PATH}/master_slc/bin:$PATH


# source the ciop functions (e.g. ciop-log)
[ "${mode}" != "test" ] && source ${ciop_job_include}

source ${_CIOP_APPLICATION_PATH}/lib/stamps-helpers.sh

# source StaMPS
source /opt/StaMPS_v3.3b1/StaMPS_CONFIG.bash

# define the exit codes
SUCCESS=0
ERR_ORBIT_FLAG=5
ERR_MASTER_EMPTY=7
ERR_MASTER_SENSING_DATE=9
ERR_MISSION_MASTER=11 
ERR_AUX=13
ERR_SLC=15 
ERR_MASTER_SETUP=16
ERR_SLC_AUX_TAR=17
ERR_SLC_AUX_PUBLISH=19
ERR_SLC_TAR=21
ERR_SLC_PUBLISH=23


# add a trap to exit gracefully
function cleanExit() {
  local retval=$?
  local msg

  msg=""
  case "${retval}" in
    ${SUCCESS}) msg="Processing successfully concluded";;
    ${ERR_ORBIT_FLAG}) msg="Failed to determine which orbit files to use";;
    ${ERR_MASTER_EMPTY}) msg="Couldn't retrieve master";;
    ${ERR_MASTER_SENSING_DATE}) msg="Couldn't retrieve master sensing date";;
    ${ERR_MISSION_MASTER}) msg="Couldn't determine master mission";;
    ${ERR_AUX}) msg="Couldn't retrieve auxiliary files";;
    ${ERR_SLC}) msg="Failed to process slc";;
    ${ERR_SLC_AUX_TAR}) msg="Failed to create archive with master ROI_PAC aux files";;
    ${ERR_SLC_AUX_PUBLISH}) msg="Failed to publish archive with master ROI_PAC aux files";;
    ${ERR_SLC_TAR}) msg="Failed to create archive with master slc";;
    ${ERR_SLC_PUBLISH}) msg="Failed to publish archive with master slc";;
  esac
   
  [ "${retval}" != "0" ] && ciop-log "ERROR" \
    "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"

  [ -n "${TinMPDIR}" ] && rm -rf ${TMPDIR}
  [ "${mode}" == "test" ] && return ${retval} || exit ${retval}
}

trap cleanExit EXIT


main() {
  local res

  # creates the adore directory structure
  ciop-log "INFO" "creating the directory structure"
  set_env
  
  # which orbits
  orbits="$( get_orbit_flag )"
  [ $? -ne 0 ] && return ${ERR_ORBIT_FLAG}
  
  master_ref="$( ciop-getparam master )"
  
  ciop-log "INFO" "Retrieving master"
  master=$( get_data ${master_ref} ${TMPDIR} )
  [ $? -ne 0 ] && return ${ERR_MASTER_EMPTY}
  
  sensing_date=$( get_sensing_date ${master} )
  [ $? -ne 0 ] && return ${ERR_MASTER_SENSING_DATE}
  
  mission=$( get_mission ${master} | tr "A-Z" "a-z" )
  [ $? -ne 0 ] && return ${ERR_MISSION_MASTER}
  [ ${mission} == "asar" ] && flag="envi"
  
  # TODO manage ERS and ALOS
  # [ ${mission} == "alos" ] && flag="alos"
  # [ ${mission} == "ers" ] && flag="ers"
  # [ ${mission} == "ers_envi" ] && flag="ers_envi"
  
  master_folder=${TMPDIR}/SLC/${sensing_date}
  mkdir -p ${master_folder}
  
  get_aux ${mission} ${sensing_date} ${orbits} 
  [ $? -ne 0 ] && return ${ERR_AUX}
  
  cd ${master_folder}
  slc_bin="step_slc_${flag}$( [ ${orbits} == "VOR" ] && [ ${mission} == "asar" ] && echo "_vor" )"
  ciop-log "INFO" "Run ${slc_bin} for ${sensing_date}"
  ln -s ${master}   
  ${slc_bin}
  [ $? -ne 0 ] && return ${ERR_SLC}
 
  # TODO check with expert what are ALL the processing steps for the master
  

  MAS_WIDTH=`grep WIDTH  ${sensing_date}.slc.rsc | awk '{print $2}' `
  MAS_LENGTH=`grep FILE_LENGTH  ${sensing_date}.slc.rsc | awk '{print $2}' `

  ciop-log "INFO" "Will run step_master_setup"
  echo "first_l 1" > master_crop.in
  echo "last_l $MAS_LENGTH" >> master_crop.in
  echo "first_p 1" >> master_crop.in
  echo "last_p $MAS_WIDTH" >> master_crop.in
  step_master_setup
  [ $? -ne 0 ] && return ${ERR_MASTER_SETUP} 

  # package 
  cd ${TMPDIR}/SLC
  tar cvfz txt.tgz ar.txt looks.txt
  [ $? -ne 0 ] && return ${ERR_SLC_AUX_TAR}
   
  txt_ref="$( ciop-publish -a ${TMPDIR}/SLC/txt.tgz )" 
  [ $? -ne 0 ] && return ${ERR_SLC_AUX_PUBLISH}
  rm -f txt.tgz 
 
  cd ${TMPDIR}
  tar cvfz master_${sensing_date}.tgz SLC INSAR_${sensing_date} 
#${sensing_date}.tgz ${sensing_date}
  [ $? -ne 0 ] && return ${ERR_SLC_TAR}
  master_slc_ref="$( ciop-publish -a ${TMPDIR}/master_${sensing_date}.tgz )"
  [ $? -ne 0 ] && return ${ERR_SLC_PUBLISH}
  
  while read slave_ref; do
    echo "${master_slc_ref},${txt_ref},${slave_ref}" | ciop-publish -s
  done
}

cat | main 
#res=$?
#[ ${res} -ne 0 ] && exit ${res}
#[ "${mode}" != "test" ] && exit 0
exit ${SUCCESS}
