#!/usr/bin/env bash
set -x

DNSMASQ_CONF_DIR="/var/run/dnsmasq-bm"
DNSMASQ_CONF_FILE="${DNSMASQ_CONF_DIR}/dnsmasq-bm.conf"
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

read_config()
{
    config_file=$1
    
    if [ -z ${config_file+defined} ]; then
        echo "Missing config file arg..."
        usage
        exit 1
    fi
    
    if [ ! -e "${config_file}" ]; then
        echo "Config file: ${config_file}, does not exist..."
        exit 1
    fi
    
    source "${config_file}"
    
    check_var BASE_DOMAIN ${config_file}
    check_var CLUSTER_NAME ${config_file}
    check_var INT_IF ${config_file}
}

stop_dnsmasq()
{
    if [ -e ${DNSMASQ_PID_FILE} ]; then
        pid=$(cat ${DNSMASQ_PID_FILE})
        sudo kill $pid
    fi
}

start_dnsmasq()
{
    stop_dnsmasq
    sudo dnsmasq -x ${DNSMASQ_PID_FILE} -q -C ${DNSMASQ_CONF_FILE}
}

create_dnsmasq_conf()
{
    sudo mkdir -p ${DNSMASQ_CONF_DIR}
    
    {
  cat << EOF
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
    } | sudo dd of=${DNSMASQ_CONF_FILE}
    
}

setup_bridge()
{
    bridge=$1
    intf=$2
    ip_address=$3
    ip_netmask=$4

    if [ -z ${bridge} ]; then
        echo "Missing bridge arg..."
        exit 1
    fi
    
    if [ -z ${intf} ]; then
        echo "Missing interface arg..."
        exit 1
    fi
    
    echo -e "DEVICE=${bridge}\nTYPE=Bridge\nONBOOT=yes\nNM_CONTROLLED=no\nIPADDR=${ip_address}\nNETMASK=${ip_netmask}" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-${bridge}
    
    sudo ifdown ${bridge} || true
    sudo ifup ${bridge}
    
    echo -e "DEVICE=${intf}\nTYPE=Ethernet\nONBOOT=yes\nNM_CONTROLLED=no\nBRIDGE=${bridge}" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-${intf}

    sudo systemctl restart network
}

COMMAND=$1

case "$COMMAND" in
    start)
        read_config $2
        create_dnsmasq_conf
        setup_bridge "baremetal" $INT_IF "192.168.111.1" "255.255.255.0"
        start_dnsmasq
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


