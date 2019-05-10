#!/usr/bin/env bash
set -x


nthhost()
{
    address="$1"
    nth="$2"
    
    ips=($(nmap -n -sL $address 2>&1 | awk '/Nmap scan report/{print $NF}'))
    ips_len="${#ips[@]}"
    
    if [ "$ips_len" -eq 0 ] || [ "$nth" -gt "$ips_len" ]; then
        echo "Invalid address: $address or offset $nth"
        exit 1
    fi
    
    echo ${ips[$nth]}
}

EXTERNAL_INTERFACE="eno1"

BM_BRIDGE="baremetal"
BM_BRIDGE_CIDR="192.168.111.0/24"
BM_BRIDGE_NETMASK="255.255.255.0"
BM_BRIDGE_IP=$(nthhost "$BM_BRIDGE_CIDR" 1)

API_VIP=$(nthhost "$BM_BRIDGE_CIDR" 5)
INGRESS_VIP=$(nthhost "$BM_BRIDGE_CIDR" 4)

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

add_rule() 
{
    rule=$1

    if ! sudo iptables -C "$rule" 2>/dev/null ; then
      sudo iptables -I "$rule"
    fi
}

start_dnsmasq()
{
    bridge=$1

    stop_dnsmasq
    sudo dnsmasq -x ${DNSMASQ_PID_FILE} -q -C ${DNSMASQ_CONF_FILE}
    
    #allow DNS/DHCP traffic to dnsmasq
    add_rule "INPUT -i "$bridge" -p udp -m udp --dport 67 -j ACCEPT"
    add_rule "INPUT -i "$bridge" -p udp -m udp --dport 53 -j ACCEPT"

    #enable routing from cluster network to external
    add_rule "-t nat POSTROUTING -o $EXTERNAL_INTERFACE -j MASQUERADE"
    add_rule "FORWARD -i $bridge -o $EXTERNAL_INTERFACE -j ACCEPT"
    add_rule "FORWARD -i $bridge -o $EXTERNAL_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT"
}

create_dnsmasq_conf()
{
    bridge="$1"
    
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
interface=${bridge}
dhcp-range=192.168.111.20,192.168.111.60
dhcp-no-override
dhcp-authoritative
dhcp-lease-max=41
dhcp-hostsfile=${DNSMASQ_CONF_DIR}/${BM_BRIDGE}.hostsfile
addn-hosts=${DNSMASQ_CONF_DIR}/${BM_BRIDGE}.addnhosts
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

setup_host_dns()
{
    
    echo "address=/api.${CLUSTER_NAME}.${BASE_DOMAIN}/${API_VIP}" | sudo tee /etc/NetworkManager/dnsmasq.d/openshift.conf
    echo "address=/.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${INGRESS_VIP}" | sudo tee -a /etc/NetworkManager/dnsmasq.d/openshift.conf

    sudo systemctl reload NetworkManager  
}

COMMAND=$1

case "$COMMAND" in
    start)
        read_config $2
        create_dnsmasq_conf ${BM_BRIDGE}
        setup_bridge ${BM_BRIDGE} $INT_IF ${BM_BRIDGE_IP} ${BM_BRIDGE_NETMASK}
        setup_host_dns
        start_dnsmasq ${BM_BRIDGE}
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


