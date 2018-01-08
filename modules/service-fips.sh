# shellcheck disable=SC2034,SC2039

FIPS_SERVICE_TITLE="Canonical FIPS 140-2 Modules"
FIPS_SUPPORTED_SERIES="xenial"
FIPS_SUPPORTED_ARCHS="x86_64 ppc64le s390x"

FIPS_REPO_URL="https://private-ppa.launchpad.net/ubuntu-advantage/fips"
FIPS_REPO_KEY_FILE="ubuntu-fips-keyring.gpg"
FIPS_REPO_LIST=${FIPS_REPO_LIST:-"/etc/apt/sources.list.d/ubuntu-fips-${SERIES}.list"}
FIPS_REPO_PREFERENCES=${FIPS_REPO_PREFERENCES:-"/etc/apt/preferences.d/ubuntu-fips-${SERIES}"}
FIPS_ENABLED_FILE=${FIPS_ENABLED_FILE:-"/proc/sys/crypto/fips_enabled"}
if [ "$ARCH" = "s390x" ]; then
    FIPS_BOOT_CFG=${FIPS_BOOT_CFG:-"/etc/zipl.conf"}
else
    FIPS_BOOT_CFG_DIR=${FIPS_BOOT_CFG_DIR:-"/etc/default/grub.d"}
    FIPS_BOOT_CFG=${FIPS_BOOT_CFG:-"${FIPS_BOOT_CFG_DIR}/99-fips.cfg"}
fi
FIPS_HMAC_PACKAGES="openssh-client-hmac openssh-server-hmac libssl1.0.0-hmac \
        linux-fips strongswan-hmac"

fips_enable() {
    local token="$1"

    _fips_check_packages_installed || error_exit service_already_enabled

    check_token "$FIPS_REPO_URL" "$token"
    apt_add_repo "$FIPS_REPO_LIST" "$FIPS_REPO_URL" "$token" \
                 "${KEYRINGS_DIR}/${FIPS_REPO_KEY_FILE}"
    apt_add_repo_pinning "$FIPS_REPO_PREFERENCES" \
                         LP-PPA-ubuntu-advantage-fips 1001
    install_package_if_missing_file "$APT_METHOD_HTTPS" apt-transport-https
    install_package_if_missing_file "$CA_CERTIFICATES" ca-certificates
    echo -n 'Running apt-get update... '
    check_result apt_get update
    echo 'Ubuntu FIPS PPA repository enabled.'

    # install all the fips packages
    echo -n 'Installing FIPS packages (this may take a while)... '
    check_result apt_get install openssh-client openssh-client-hmac \
                 openssh-server openssh-server-hmac openssl libssl1.0.0 \
                 libssl1.0.0-hmac fips-initramfs linux-fips \
                 strongswan strongswan-hmac

    echo "Configuring FIPS... "
    _fips_configure
    echo "Successfully configured FIPS. Please reboot into the FIPS kernel to enable it."
}

fips_disable() {
    not_supported 'Disabling FIPS'
}

fips_is_enabled() {
    is_package_installed fips-initramfs && [ "$(_fips_enabled_check)" -eq 1 ]
}

fips_validate_token() {
    local token="$1"

    if ! validate_user_pass_token "$token"; then
        error_msg 'Invalid token, it must be in the form "user:password"'
        return 1
    fi
}

fips_check_support() {
    local power_cpu_ver
    case "$ARCH" in
        x86_64)
            if ! check_cpu_flag aes; then
                error_msg 'FIPS requires AES CPU extensions'
                error_exit arch_not_supported
            fi
            ;;

        ppc64le)
            power_cpu_ver="$(power_cpu_version)"
            if [ -z "$power_cpu_ver" ] || [ "$power_cpu_ver" -lt 8 ]; then
                error_msg 'FIPS requires POWER8 or later'
                error_exit arch_not_supported
            fi
            ;;
    esac
}

_fips_configure() {
    local bootdev fips_params result

    # if /boot has its own partition, then get the bootdevice
    # Note: /boot/efi  does not count
    bootdev=$(awk '!/^\s*#/ && $2 ~ /^\/boot\/?$/ { print $1 }' "$FSTAB")
    fips_params="fips=1"
    if [ -n "$bootdev" ]; then
        fips_params="$fips_params bootdev=$bootdev"
    fi

    if [ "$ARCH" = "s390x" ]; then
        sed -i -e 's,^parameters\s*=.*,& '"$fips_params"',' "$FIPS_BOOT_CFG"
        echo -n 'Updating zipl to enable fips... '
        check_result zipl
    else
        result=0
        if [ ! -d "$FIPS_BOOT_CFG_DIR" ]; then
            mkdir "$FIPS_BOOT_CFG_DIR" >/dev/null 2>&1 || result=$?
            if [ $result -ne 0 ]; then
                error_msg "Failed to make directory, $FIPS_BOOT_CFG_DIR."
                return 1
            fi
        fi
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $fips_params\"" >"$FIPS_BOOT_CFG"
        echo -n 'Updating grub to enable fips... '
        check_result update-grub
    fi
}

_fips_enabled_check() {
    if [ -f "$FIPS_ENABLED_FILE" ]; then
        cat "$FIPS_ENABLED_FILE"
        return
    fi
    echo 0
}

_fips_check_packages_installed() {
    local pkg
    for pkg in $FIPS_HMAC_PACKAGES; do
        if is_package_installed "$pkg"; then
            if fips_is_enabled; then
                error_msg "FIPS is already enabled."
            else
                error_msg "FIPS is already installed. Please reboot into the FIPS kernel to enable it."
            fi
            return 1
        fi
    done
}
