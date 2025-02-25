#!/bin/bash

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}

function checkVirt() {
	if [ "$(systemd-detect-virt)" == "openvz" ]; then
		echo "OpenVZ is not supported"
		exit 1
	fi

	if [ "$(systemd-detect-virt)" == "lxc" ]; then
		echo "LXC is not supported."
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 10 ]]; then
			echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
			exit 1
		fi
		OS=debian # overwrite if raspbian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 18.04 or later"
			exit 1
		fi
	else
		echo "Looks like you aren't running this installer on a Debian/Raspbian or Ubuntu system"
		exit 1
	fi
}

function getHomeDirForClient() {
	local CLIENT_NAME=$1

	if [ -z "${CLIENT_NAME}" ]; then
		echo "Error: getHomeDirForClient() requires a client name as argument"
		exit 1
	fi

	# Home directory of the user, where the client configuration will be written
	if [ -e "/home/${CLIENT_NAME}" ]; then
		# if $1 is a user name
		HOME_DIR="/home/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ]; then
		# if not, use SUDO_USER
		if [ "${SUDO_USER}" == "root" ]; then
			# If running sudo as root
			HOME_DIR="/root"
		else
			HOME_DIR="/home/${SUDO_USER}"
		fi
	else
		# if not SUDO_USER, use /root
		HOME_DIR="/root"
	fi

	echo "$HOME_DIR"
}

function initialCheck() {
	isRoot
	checkVirt
	checkOS
}

function installQuestions() {
	echo "Welcome to the WireGuard installer!"
	echo "I need to ask you a few questions before starting the setup."
	echo "You can keep the default options and just press enter if you are ok with them."
	echo ""

	# Detect public IPv4 or IPv6 address and pre-fill for the user
	SERVER_PUB_IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	if [[ -z ${SERVER_PUB_IP} ]]; then
		# Detect public IPv6 address
		SERVER_PUB_IP=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi
	read -rp "IPv4 or IPv6 public address: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP

	# Detect public interface and pre-fill for the user
	SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
		read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
	done

	until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
		read -rp "WireGuard interface name: " -e -i wg0 SERVER_WG_NIC
	done

	until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		read -rp "Server WireGuard IPv4: " -e -i 10.0.0.1 SERVER_WG_IPV4
	done

	until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
		read -rp "Server WireGuard IPv6: " -e -i fd42:42:42::1 SERVER_WG_IPV6
	done

	# Generate random number within specified range
    RANDOM_PORT=$(shuf -i65523-65535 -n1)
    until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 65523 ] && [ "${SERVER_PORT}" -le 65535 ]; do
    read -rp "Server WireGuard port [65523-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
    done
    # Check if ssh is in range
	 if [[ (${SSH_CLIENT##* } -ge 1 && ${SSH_CLIENT##* } -le 65500 ) ]]; then
		read -p "BE ADVISED! SSH Port will be changed from ${SSH_CLIENT##* } to 65522!"
		sed -i 's/#Port\s\+[0-9]\+/Port 65522/' /etc/ssh/sshd_config
		# Restart ssh service
		#systemctl restart ssh.service
	 fi

	# Adguard DNS by default
	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "First DNS resolver to use for the clients: " -e -i 1.1.1.1 CLIENT_DNS_1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Second DNS resolver to use for the clients (optional): " -e -i 1.0.0.1 CLIENT_DNS_2
		if [[ ${CLIENT_DNS_2} == "" ]]; then
			CLIENT_DNS_2="${CLIENT_DNS_1}"
		fi
	done

	until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
		echo -e "\nWireGuard uses a parameter called AllowedIPs to determine what is routed over the VPN."
		read -rp "Allowed IPs list for generated clients (leave default to route everything): " -e -i '0.0.0.0/0,::/0' ALLOWED_IPS
		if [[ ${ALLOWED_IPS} == "" ]]; then
			ALLOWED_IPS="0.0.0.0/0,::/0"
		fi
	done

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your WireGuard server now."
	echo "You will be able to generate a client at the end of the installation."
	read -n1 -r -p "Press any key to continue..."
}

function installWireGuard() {
	# Run setup questions first
	installQuestions

	# Install WireGuard tools and module
if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
    apt-get update
    apt-get install -y wireguard iptables resolvconf qrencode
elif [[ ${OS} == 'debian' ]]; then
    if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
        echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
        apt-get update
    fi
    apt update
    apt-get install -y iptables resolvconf qrencode
    apt-get install -y -t buster-backports wireguard
fi

	# Make sure the directory exists (this does not seem the be the case on fedora)
	mkdir /etc/wireguard >/dev/null 2>&1

	chmod 600 -R /etc/wireguard/

	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# Save WireGuard settings
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}" >/etc/wireguard/params

	# Add server interface
	echo "[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
PostUp = /etc/wireguard/add-fullcone-nat.sh
PostDown = /etc/wireguard/rm-fullcone-nat.sh" >"/etc/wireguard/${SERVER_WG_NIC}.conf"

# add-fullcone-nat.sh and rm-fullcone-nat.sh
	echo "#!/bin/bash

iptables -A FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
iptables -A FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
ip6tables -A FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
ip6tables -A FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" > "/etc/wireguard/add-fullcone-nat.sh"

echo "#!/bin/bash

iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
ip6tables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" > "/etc/wireguard/rm-fullcone-nat.sh"

	# Add exec permission
	chmod u+x /etc/wireguard/add-fullcone-nat.sh
	chmod u+x /etc/wireguard/rm-fullcone-nat.sh

# Create the wg-json file
cat > /etc/wireguard/wg-json << 'EOL'
#!/bin/bash
# Your wg-json script content here ...
exec < <(exec wg show all dump)

printf '{'
while read -r -d $'\t' device; do
	if [[ $device != "$last_device" ]]; then
		[[ -z $last_device ]] && printf '\n' || printf '%s,\n' "$end"
		last_device="$device"
		read -r private_key public_key listen_port fwmark
		printf '\t"%s": {' "$device"
		delim=$'\n'
		[[ $private_key == "(none)" ]] || { printf '%s\t\t"privateKey": "%s"' "$delim" "$private_key"; delim=$',\n'; }
		[[ $public_key == "(none)" ]] || { printf '%s\t\t"publicKey": "%s"' "$delim" "$public_key"; delim=$',\n'; }
		[[ $listen_port == "0" ]] || { printf '%s\t\t"listenPort": %u' "$delim" $(( $listen_port )); delim=$',\n'; }
		[[ $fwmark == "off" ]] || { printf '%s\t\t"fwmark": %u' "$delim" $(( $fwmark )); delim=$',\n'; }
		printf '%s\t\t"peers": {' "$delim"; end=$'\n\t\t}\n\t}'
		delim=$'\n'
	else
		read -r public_key preshared_key endpoint allowed_ips latest_handshake transfer_rx transfer_tx persistent_keepalive
		printf '%s\t\t\t"%s": {' "$delim" "$public_key"
		delim=$'\n'
		[[ $preshared_key == "(none)" ]] || { printf '%s\t\t\t\t"presharedKey": "%s"' "$delim" "$preshared_key"; delim=$',\n'; }
		[[ $endpoint == "(none)" ]] || { printf '%s\t\t\t\t"endpoint": "%s"' "$delim" "$endpoint"; delim=$',\n'; }
		[[ $latest_handshake == "0" ]] || { printf '%s\t\t\t\t"latestHandshake": %u' "$delim" $(( $latest_handshake )); delim=$',\n'; }
		[[ $transfer_rx == "0" ]] || { printf '%s\t\t\t\t"transferRx": %u' "$delim" $(( $transfer_rx )); delim=$',\n'; }
		[[ $transfer_tx == "0" ]] || { printf '%s\t\t\t\t"transferTx": %u' "$delim" $(( $transfer_tx )); delim=$',\n'; }
		[[ $persistent_keepalive == "off" ]] || { printf '%s\t\t\t\t"persistentKeepalive": %u' "$delim" $(( $persistent_keepalive )); delim=$',\n'; }
		printf '%s\t\t\t\t"allowedIps": [' "$delim"
		delim=$'\n'
		if [[ $allowed_ips != "(none)" ]]; then
			old_ifs="$IFS"
			IFS=,
			for ip in $allowed_ips; do
				printf '%s\t\t\t\t\t"%s"' "$delim" "$ip"
				delim=$',\n'
			done
			IFS="$old_ifs"
			delim=$'\n'
		fi
		printf '%s\t\t\t\t]' "$delim"
		printf '\n\t\t\t}'
		delim=$',\n'
	fi


done
printf '%s\n' "$end"
printf '}\n'

EOL

# Make the wg-json file executable
chmod +x /etc/wireguard/wg-json
	
	

	# Enable routing on the server
	echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/wg.conf

	sysctl --system

	systemctl start "wg-quick@${SERVER_WG_NIC}"
	systemctl enable "wg-quick@${SERVER_WG_NIC}"

	newClient
	echo -e "${GREEN}If you want to add more clients, you simply need to run this script another time!${NC}"

	# Check if WireGuard is running
	systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
	WG_RUNNING=$?

	# WireGuard might not work if we updated the kernel. Tell the user to reboot
	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}WARNING: WireGuard does not seem to be running.${NC}"
		echo -e "${ORANGE}You can check if WireGuard is running with: systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
		echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_WG_NIC}\", please reboot!${NC}"
	else # WireGuard is running
		echo -e "\n${GREEN}WireGuard is running.${NC}"
		echo -e "${GREEN}You can check the status of WireGuard with: systemctl status wg-quick@${SERVER_WG_NIC}\n\n${NC}"
		echo -e "${ORANGE}If you don't have internet connectivity from your client, try to reboot the server.${NC}"
	fi
}

function validate_ipv6() {
    local ipv6="$1"
    local addr
    local mask

    # Split the address and mask
    IFS="/" read -r addr mask <<< "$ipv6"

    # Check if valid IPv6
    [[ $addr =~ ^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$ ]] || return 1

    # Check if mask is between /40 to /128
    [[ "$mask" -ge 40 && "$mask" -le 128 ]] || return 1

    return 0
}



function newClient() {
	# If SERVER_PUB_IP is IPv6, add brackets if missing
	if [[ ${SERVER_PUB_IP} =~ .*:.* ]]; then
		if [[ ${SERVER_PUB_IP} != *"["* ]] || [[ ${SERVER_PUB_IP} != *"]"* ]]; then
			SERVER_PUB_IP="[${SERVER_PUB_IP}]"
		fi
	fi
	ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

	echo ""
	echo "Client configuration"
	echo ""
	echo "The client name must consist of alphanumeric character(s). It may also include underscores or dashes and can't exceed 15 chars."

	until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
		read -rp "Client name: " -e CLIENT_NAME
		CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${CLIENT_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified name was already created, please choose another name.${NC}"
			echo ""
		fi
	done

	for DOT_IP in {2..254}; do
		DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "/etc/wireguard/${SERVER_WG_NIC}.conf")
		if [[ ${DOT_EXISTS} == '0' ]]; then
			break
		fi
	done

	if [[ ${DOT_EXISTS} == '1' ]]; then
		echo ""
		echo "The subnet configured supports only 253 clients."
		exit 1
	fi

	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	until [[ ${IPV4_EXISTS} == '0' ]]; do
		read -rp "Client WireGuard IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"
		IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/32" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${IPV4_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified IPv4 was already created, please choose another IPv4.${NC}"
			echo ""
		fi
	done

	 # This part will ask the user if the ipv6 is public or private 

	while true; do
    read -rp "Would you like to input a public IPv6 subnet? [y/N]: " DECISION

    case ${DECISION,,} in
        y)
            while true; do
                read -rp "Please enter the public IPv6 subnet (from /40 to /128): " CLIENT_WG_IPV6

                # Validate IPv6 subnet
                if validate_ipv6 "$CLIENT_WG_IPV6"; then
                    # Check if the subnet is already in use
                    SUBNET_EXISTS=$(grep -c "${CLIENT_WG_IPV6}" "/etc/wireguard/${SERVER_WG_NIC}.conf")
                    if [[ ${SUBNET_EXISTS} != 0 ]]; then
                        echo ""
                        echo -e "${ORANGE}The subnet you provided is already in use. Please choose another subnet.${NC}"
                        echo ""
                    else
                        break
                    fi
                else
                    echo "Invalid subnet. Please enter a valid IPv6 subnet with mask from /40 to /128."
                fi
            done
            break
            ;;

        ""|n)
            # Original script you provided for auto-generating and ensuring uniqueness of IPv6 address.
            BASE_IP=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
            until [[ ${IPV6_EXISTS} == '0' ]]; do
                read -rp "Client WireGuard IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
                CLIENT_WG_IPV6="${BASE_IP}::${DOT_IP}"
                IPV6_EXISTS=$(grep -c "${CLIENT_WG_IPV6}/128" "/etc/wireguard/${SERVER_WG_NIC}.conf")

                if [[ ${IPV6_EXISTS} != 0 ]]; then
                    echo ""
                    echo -e "${ORANGE}A client with the specified IPv6 was already created, please choose another IPv6.${NC}"
                    echo ""
                fi
            done
            break
            ;;

        *)
            echo "Invalid input. Please enter 'y' or 'n'."
            ;;
    esac
done


	# Generate key pair for the client
	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

	# Create client file and add the server as a peer
	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	# Add the client as a peer to the server
	echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	# Generate QR code if qrencode is installed
	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
		qrencode -t ansiutf8 -l L <"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
		echo ""
	fi

	echo -e "${GREEN}Your client config file is in ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"
}

function listClients() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
		echo ""
		echo "You have no existing clients!"
		exit 1
	fi

	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
}

function revokeClient() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo ""
		echo "You have no existing clients!"
		exit 1
	fi

	echo ""
	echo "Select the existing client you want to revoke"
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one client [1]: " CLIENT_NUMBER
		else
			read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done

	# match the selected number to a client name
	CLIENT_NAME=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

	# remove [Peer] block matching $CLIENT_NAME
	sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

	# remove generated client file
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	# restart wireguard to apply changes
	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")
}

function uninstallWg() {
	echo ""
	echo -e "\n${RED}WARNING: This will uninstall WireGuard and remove all the configuration files!${NC}"
	echo -e "${ORANGE}Please backup the /etc/wireguard directory if you want to keep your configuration files.\n${NC}"
	read -rp "Do you really want to remove WireGuard? [y/n]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ $REMOVE == 'y' ]]; then
		checkOS

		systemctl stop "wg-quick@${SERVER_WG_NIC}"
		systemctl disable "wg-quick@${SERVER_WG_NIC}"

		if [[ ${OS} == 'ubuntu' ]]; then
			apt-get remove -y wireguard wireguard-tools qrencode
		elif [[ ${OS} == 'debian' ]]; then
			apt-get remove -y wireguard wireguard-tools qrencode
		elif [[ ${OS} == 'fedora' ]]; then
			dnf remove -y --noautoremove wireguard-tools qrencode
			if [[ ${VERSION_ID} -lt 32 ]]; then
				dnf remove -y --noautoremove wireguard-dkms
				dnf copr disable -y jdoss/wireguard
			fi
		elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
			yum remove -y --noautoremove wireguard-tools
			if [[ ${VERSION_ID} == 8* ]]; then
				yum remove --noautoremove kmod-wireguard qrencode
			fi
		elif [[ ${OS} == 'oracle' ]]; then
			yum remove --noautoremove wireguard-tools qrencode
		elif [[ ${OS} == 'arch' ]]; then
			pacman -Rs --noconfirm wireguard-tools qrencode
		fi

		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/wg.conf

		# Reload sysctl
		sysctl --system

		# Check if WireGuard is running
		systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
		WG_RUNNING=$?

		if [[ ${WG_RUNNING} -eq 0 ]]; then
			echo "WireGuard failed to uninstall properly."
			exit 1
		else
			echo "WireGuard uninstalled successfully."
			exit 0
		fi
	else
		echo ""
		echo "Removal aborted!"
	fi
}


function enableIPv6Use() {
    # Paths to the scripts
    ADD_FULLCONE_NAT="/etc/wireguard/add-fullcone-nat.sh"
    RM_FULLCONE_NAT="/etc/wireguard/rm-fullcone-nat.sh"

    # Rules to check for
    RULE_ADD="ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"
    RULE_RM="ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"

    # Check in add-fullcone-nat.sh
    if grep -q -F "${RULE_ADD}" "${ADD_FULLCONE_NAT}"; then
        # Comment the rule if it's present
        sed -i "s|${RULE_ADD}|#${RULE_ADD}|" "${ADD_FULLCONE_NAT}"
        echo "IPv6 NAT rule commented out in ${ADD_FULLCONE_NAT}"
    fi

    # Check in rm-fullcone-nat.sh
    if grep -q -F "${RULE_RM}" "${RM_FULLCONE_NAT}"; then
        # Comment the rule if it's present
        sed -i "s|${RULE_RM}|#${RULE_RM}|" "${RM_FULLCONE_NAT}"
        echo "IPv6 NAT rule commented out in ${RM_FULLCONE_NAT}"
    fi

    echo "Changes made. Please remember to reboot to apply them."
}

function disableIPv6Use() {
    # Paths to the scripts
    ADD_FULLCONE_NAT="/etc/wireguard/add-fullcone-nat.sh"
    RM_FULLCONE_NAT="/etc/wireguard/rm-fullcone-nat.sh"

    # Rules to check for
    RULE_ADD="ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"
    RULE_RM="ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"

    # Check in add-fullcone-nat.sh
    if grep -q -F "#${RULE_ADD}" "${ADD_FULLCONE_NAT}"; then
        # Uncomment the rule if it's present
        sed -i "s|#${RULE_ADD}|${RULE_ADD}|" "${ADD_FULLCONE_NAT}"
        echo "IPv6 NAT rule uncommented in ${ADD_FULLCONE_NAT}"
    fi

    # Check in rm-fullcone-nat.sh
    if grep -q -F "#${RULE_RM}" "${RM_FULLCONE_NAT}"; then
        # Uncomment the rule if it's present
        sed -i "s|#${RULE_RM}|${RULE_RM}|" "${RM_FULLCONE_NAT}"
        echo "IPv6 NAT rule uncommented in ${RM_FULLCONE_NAT}"
    fi

    echo "Changes made. Please remember to reboot to apply them."
}

function displayConnectedClients() {
    # Assuming wg-json script is executable and in /etc/wireguard
    local wg_json_output
    wg_json_output=$(/etc/wireguard/wg-json)

    echo "+-----------------------+-------------------+---------------------+---------------------+---------------------+"
    echo "| Client IP             | Last Handshake    | Status              | Endpoint            | Data Transferred    |"
    echo "+-----------------------+-------------------+---------------------+---------------------+---------------------+"

    # Parsing the JSON using jq
    echo "$wg_json_output" | jq -r 'to_entries[] | .value.peers | to_entries[] | 
        if .value.latestHandshake == 0 then
            "\(.value.allowedIps[0]) | Never | Never Connected | \(.value.endpoint // "Not set") | \((.value.transferRx // 0) + (.value.transferTx // 0) | tostring)"
        elif .value.latestHandshake | type == "number" then
            "\(.value.allowedIps[0]) | \(.value.latestHandshake | todate) | Connected | \(.value.endpoint // "Not set") | \( ((.value.transferRx // 0) + (.value.transferTx // 0)) / 1048576 | tostring + " MB")"
        else
            "\(.value.allowedIps[0]) | Never | Never Connected | Not set | 0"
        end' | while read line; do
        echo "| $line |"
    done

    echo "+-----------------------+-------------------+---------------------+---------------------+---------------------+"
}





function manageMenu() {
    echo "Welcome to WireGuard-install!"
    echo "It looks like WireGuard is already installed."
    echo ""
    echo "What do you want to do?"
    echo "   1) Add a new user"
    echo "   2) List all users"
    echo "   3) Remove an existing user"
    echo "   4) Uninstall WireGuard"
    echo "   5) Enable Public IPv6 Use"
    echo "   6) Disable Public IPv6 Use"
    echo "   7) Display connected clients"
    echo "   8) Exit"
    until [[ ${MENU_OPTION} =~ ^[1-8]$ ]]; do
        read -rp "Select an option [1-8]: " MENU_OPTION
    done
    case "${MENU_OPTION}" in
    1)
        newClient
        ;;
    2)
        listClients
        ;;
    3)
        revokeClient
        ;;
    4)
        uninstallWg
        ;;
    5)
        enableIPv6Use
        ;;
    6)
        disableIPv6Use
        ;;
    7)
        displayConnectedClients
        ;;
    8)
        exit 0
        ;;
    esac
}


# Check for root, virt, OS...
initialCheck

# Check if WireGuard is already installed and load params
if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params
	manageMenu
else
	installWireGuard
fi







