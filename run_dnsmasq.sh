#!/usr/bin/env bash
set -x

DNSMASQ_CONF_DIR="/var/run/dnsmasq-bm"
DNSMASQ_PID_FILE="${DNSMASQ_CONF_DIR}/dnsmasq-bm.pid"

cleanup() {
  echo "$? cleanup $1"
}

trap cleanup EXIT

usage() {
    cat <<EOM
    Starts/stops/installs a dnsmasq instance to serve DNS/DHCP for the baremetal network in the METAL3 environment.
    Usage:
    $(basename $0) start config_file|stop
    Starts a dnsmasq instance to serve DNS and DHCP for the baremetal network in the metal3 environment. 
        start config_file -- Start the dnsmasq instance with the variables define in the config_file.
                              The config_file is the file that is passed to metal3 deploy.
                              i.e.
                                CONFIG=.../nfvpelab.sh make
        stop              -- Stop the dnsmasq instance if it exists (checks for /var/run/${DNSMASQ_PID_FILE}
EOM
    exit 1
}

set_variable()
{
    local varname=$1
    shift
    if [ -z "${!varname}" ]; then
        eval "$varname=\"$@\""
    else
        echo "Error: $varname already set"
        usage
    fi
}

lsx

unset CONFIG_FILE
unset COMMAND

while getopts 'c:kh' c
do
    case $c in
        c) set_variable CONFIG_FILE $OPTARG ;;
        i) KILL=1 ;;
        h|?) usage ;;
    esac
done

# Shift to arguments
shift $((OPTIND-1))

if [ "$#" -lt 1 ]; then
    usage
fi

stop_dnsmasq()
{
  if [ -e "$DNSMASQ_PID_FILE" ]; then
     kill $(cat ${DNSMASQ_PID_FILE})
     if [ $? -ne 0 ]; then
       echo "Could not stop dnsmasq instance, must stop manually..."
       exit 1
     fi
     exit 0
  else
     echo "No pid file, $DNSMASQ_PID_FILE, not running or must stop manually..."
     exit 1
  fi
}

check_var()
{
    local varname=$1
    shift
    if [ -z "${!varname}" ]; then
        echo "$varname not set in ${config_file}, must define $varname"
        exit 1
    fi        
}

start_dnsmasq()
{
  config_file=$1
       
  if [ ! -e "${config_file}" ]; then
     echo "Config file: ${config_file}, does not exist..."
     exit 1
  fi

  source "${config_file}"

  check_var BASE_DOMAIN ${config_file}
  check_var CLUSTER_NAME ${config_file}
  check_var INT_IF ${config_file}

  if [ -e ${DNSMASQ_PID_FILE} ]; then
    pid=$(cat ${DNSMASQ_PID_FILE})
    kill -0 $pid
    if [ $? -ne 0 ]; then
      rm -f ${DNSMASQ_PID_FILE}
    else
      echo "baremetal dnsmasq instance is already running as PID $pid..."
      exit 1
    fi
  fi

  mkdir -p ${DNSMASQ_CONF_DIR}

  cat << EOF > ${DNSMASQ_CONF_DIR}/dnsmasq-bm.conf
strict-order
server=/apps.${CLUSTER_NAME}.${BASE_DOMAIN}/127.0.0.1 
local=/${CLUSTER_NAME}.${BASE_DOMAIN}/
domain=${CLUSTER_NAME}.${BASE_DOMAIN}
expand-hosts
pid-file=${DNSMASQ_PID_FILE}
except-interface=lo
bind-dynamic
interface=${INT_IF}
dhcp-range=192.168.111.20,192.168.111.60
dhcp-no-override
dhcp-authoritative
dhcp-lease-max=41
dhcp-hostsfile=${DNSMASQ_CONF_DIR}/baremetal.hostsfile
addn-hosts=${DNSMASQ_CONF_DIR}/baremetal.addnhosts
EOF

}

setup_bridge()
{
    bridge=$1
    intf=$2

    if [ -e /etc/sysconfig/network-scripts/ifcfg-${bridge} ] ; then
        echo "Bridge ${bridge} already define!  Undefine/remove before running.."
        exit 1
        echo -e "DEVICE=baremetal\nTYPE=Bridge\nONBOOT=yes\nNM_CONTROLLED=no" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-baremetal
    fi
    sudo ifdown baremetal || true
    sudo ifup baremetal

    # Add the internal interface to it if requests, this may also be the interface providing
    # external access so we need to make sure we maintain dhcp config if its available
    if [ "$INT_IF" ]; then
        echo -e "DEVICE=$INT_IF\nTYPE=Ethernet\nONBOOT=yes\nNM_CONTROLLED=no\nBRIDGE=baremetal" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-$INT_IF
        if sudo nmap --script broadcast-dhcp-discover -e $INT_IF | grep "IP Offered" ; then
            echo -e "\nBOOTPROTO=dhcp\n" | sudo tee -a /etc/sysconfig/network-scripts/ifcfg-baremetal
            sudo systemctl restart network
        else
           sudo systemctl restart network
        fi
    fi

}

COMMAND=$1

case "$COMMAND" in
     start)
       if [ -z ${2+defined} ]; then
          echo "Missing config file arg..."
          usage
       fi
       start_dnsmasq "$2"
       ;;
     stop)
       stop_dnsmasq
       ;;
     install)
       ;;
     *)
       echo "Unknown command: ${COMMAND}"
       usage
       ;;
esac


