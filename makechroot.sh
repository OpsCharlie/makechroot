#!/bin/bash
#===============================================================================
#
#          FILE: makechroot.sh
#
#         USAGE: sudo makechroot.sh
#
#   DESCRIPTION: This script can be used to create simple chroot environment
#                The script:
#                  - asks for user and password
#                  - create chroot environment with commands
#                  - adjust sshd_config
#
#       CREATED: 21-03-19 13:36:57
#      REVISION:  ---
#===============================================================================


if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi


SSHD=/etc/ssh/sshd_config
ROOT="/var/chroot"


# which commands need to be available in the chroot
# git needs: git sh basename uname tr pager ssh
# push over https: /usr/lib/git-core/git-remote-https
CMD=$(which ls locale cat echo bash tar file touch vi vim cp mv /usr/bin/rm id mkdir grep sed less)


read -p "Enter chroot user: " CHROOTUSER
CHROOT="$ROOT/$CHROOTUSER"
if [ -d "$CHROOT" ]; then
    echo "User already exists."
    read -p "Continue? [y/N]: " YN
    if [ "$YN" != "y" ]; then
        echo "Aborted."
        exit
    fi
else
    #create user
    useradd "$CHROOTUSER" -d / -s /bin/bash -c "Chroot_user" -M
    groupadd chrootjail
    usermod -a -G chrootjail "$CHROOTUSER"
    ## password logon
    #read -p "Enter chroot password: " PASSWD
    #[[ -z "$PASSWD" ]] || (echo -e "$PASSWD\n$PASSWD" | passwd "$CHROOTUSER")
fi
mkdir -p "$CHROOT"



# enable commands
for COMMAND in $( ldd $CMD | grep -v dynamic | cut -d " " -f 3 | sed 's/://' | sort | uniq ); do
    # extra for git
    if [[ $COMMAND = /usr/bin/git ]]; then
        cp --parents -r /usr/share/git-core/templates "$CHROOT"
        cp --parents -r /usr/lib/git-core/ "$CHROOT"
        install -o "$CHROOTUSER" -g "$CHROOTUSER" -m 644 /dev/null "$CHROOT"/.gitconfig
    fi
    if [[ $COMMAND = /usr/lib/git-core/git-remote-https ]]; then
        cp --parents -r /etc/ssl/ "$CHROOT"
    fi


    # extra for php
    if [[ $COMMAND = /usr/bin/php ]]; then
        cp -rfl --parents /usr/share/zoneinfo "$CHROOT"

        # get conf location
        CONF=$(php -i | grep "Configuration File.*Path")
        CONF="${CONF##C* }"
        CONFD="${CONF}/conf.d"

        # copy php conf
        cp -L --parents "${CONFD}"/* "$CHROOT"
        cp -L --parents "${CONF}/php.ini" "$CHROOT"

        # get extention dir location
        EXTDIR=$(php -i | egrep "^extension_dir")
        EXTDIR="${EXTDIR##e* }"

        # copy extension dir
        cp -L --parents "${EXTDIR}"/*.so "$CHROOT"

        # enable php modules
        for MODULE in $(ldd $(find ${EXTDIR} -type f -name "*.so") | grep -v dynamic | cut -d " " -f 3 | sed 's/://' | sort | uniq ); do
            cp --parents "$MODULE" "$CHROOT"
        done
    fi

    cp --parents "$COMMAND" "$CHROOT"
done


# ARCH amd64
if [ -f /lib64/ld-linux-x86-64.so.2 ]; then
    cp --parents /lib64/ld-linux-x86-64.so.2 "$CHROOT" 2>/dev/null
fi


#files for dns/hosts resolving
for F in libnss_files.so.2 libnss_dns.so.2; do
    CP="/lib/x86_64-linux-gnu"
    mkdir -p "$CHROOT/$CP/"
    cp --parents "$CP"/"$F" "$CHROOT"
done
cp -rfL --parents /etc/{services,localtime,resolv.conf} "$CHROOT"



##create virtual dirs and bind /dev
for D in dev sys run proc; do
    mkdir -p "$CHROOT"/$D
done
if ! mount | grep -q "$CHROOT/dev";then
    mount -o bind /dev "$CHROOT"/dev
fi



#create tmp dir
[[ -d "$CHROOT"/tmp ]] || install -d -o "$CHROOTUSER" -g "$CHROOTUSER" "$CHROOT"/tmp



#passwd
egrep "$CHROOTUSER" /etc/passwd > "$CHROOT"/etc/passwd
egrep "$CHROOTUSER" /etc/group > "$CHROOT"/etc/group



#wwwroot
[[ -d "$CHROOT"/wwwroot ]] || install -d -o "$CHROOTUSER" -g "$CHROOTUSER" "$CHROOT"/wwwroot



#create .ssh
mkdir -p "$ROOT"/.ssh
touch "$ROOT"/.ssh/authorized_keys_"$CHROOTUSER"



#create .bashrc
cat << EOF > $CHROOT/.bashrc
export HISTTIMEFORMAT="| %d.%m.%y %T =>  "
shopt -s histappend
PROMPT_COMMAND="history -a;$PROMPT_COMMAND"
PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF



#create .bash_profile
echo 'source "/.bashrc"' > "$CHROOT"/.bash_profile



#create .bash_history
[[ -f "$CHROOT"/.bash_history ]] || install -o "$CHROOTUSER" -g "$CHROOTUSER" -m 644 /dev/null "$CHROOT"/.bash_history


#vim stuff
cat << EOF > $CHROOT/.vimrc
set showmode
EOF

[[ -d "$CHROOT"/lib/terminfo/s ]] || install -d -o "root" -g "root" "$CHROOT"/lib/terminfo/s
[[ -f "$CHROOT"/lib/terminfo/s/screen-256color ]] || cp -L --parents /lib/terminfo/s/screen-256color "$CHROOT"



# sshd stuff
sed  -i 's;^Subsystem sftp /usr/lib/openssh/sftp-server;#Subsystem sftp /usr/lib/openssh/sftp-server\nSubsystem sftp internal-sftp;g' "$SSHD"

if ! egrep -q "^Match group chrootjail" "$SSHD"; then
    echo >> "$SSHD"
    echo "Match group chrootjail" >> "$SSHD"
    echo "      PubkeyAuthentication yes" >> "$SSHD"
    echo "      ChrootDirectory $ROOT/%u" >> "$SSHD"
    echo "      AuthorizedKeysFile $ROOT/.ssh/authorized_keys_%u" >> "$SSHD"
    echo "      AllowTcpForwarding no" >> "$SSHD"
    echo "      PermitTunnel no" >> "$SSHD"
    echo "      X11Forwarding no" >> "$SSHD"
    sshd -t && service ssh restart || echo "Error in $SSHD"
fi



echo -e "\n\nChrootDirectory $CHROOT"
echo "AuthorizedKeysFile $ROOT/.ssh/authorized_keys_$CHROOTUSER"
echo -e "\nChroot jail is ready. To access it execute: chroot $CHROOT"
echo -e "\n\nbindfs RO example:"
echo "   bindfs -u $CHROOTUSER -g $CHROOTUSER --perms=ug=rX  /var/www/www.example.com/versions $CHROOT/wwwroot"
echo -e "bindfs RW example:"
echo "   bindfs -g www-data -m $CHROOTUSER --create-for-user=www-data --create-for-group=www-data --create-with-perms=0644,a+X /var/www/www.example.com/wwwroot $CHROOT/wwwroot/"

