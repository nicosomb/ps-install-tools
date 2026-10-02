#!/bin/sh
#
# Usage:
#   ps-php [suffix]               Show the PHP of the instance
#   ps-php [suffix] <version>     Pin the instance to PHP <version>: CLI and PHP-FPM pool
#   ps-php [suffix] global        Back to the global PHP (php of the PATH, PHP handler of httpd.conf)
#   ps-php doctor                 Check the PHP versions, Apache, the PHP-FPM masters and pools
#
# The suffix is detected from the current folder when omitted. See tools/php.sh for the layout.

BASEDIR=$(dirname "$0")

usage() {
    echo "Command usage:"
    echo
    echo "ps-php [suffix]               Show the PHP of the instance"
    echo "ps-php [suffix] <version>     Pin the instance to PHP <version> (8.1, 8.4, ...): CLI and PHP-FPM pool"
    echo "ps-php [suffix] global        Back to the global PHP"
    echo "ps-php doctor                 Check the PHP versions, Apache, the PHP-FPM masters and pools"
}

is_php_target() {
    echo "$1" | grep -qE '^([0-9]+\.[0-9]+|global)$'
}

## Doctor

doctor() {
    local problems=0 version fpm pool folder poolVersion pinned socket status

    ok() { echo "  OK    $1"; }
    warn() { echo "  WARN  $1"; problems=$(($problems+1)); }

    echo "PHP versions ($(brew_prefix)/opt):"
    for version in $(installed_php_versions); do
        if php_fpm_binary_for_version $version > /dev/null; then
            ok "$version ($(php_folder_for_version $version))"
        else
            warn "$version has no php-fpm binary, it cannot serve an instance"
        fi
    done
    echo "  Global php: $(command -v php) ($(php -r 'echo PHP_VERSION;' 2>/dev/null))"
    echo

    echo "Apache:"
    if apache_has_proxy_fcgi; then
        ok "mod_proxy_fcgi is loaded"
    else
        warn "mod_proxy_fcgi is not loaded"
        print_apache_fpm_requirements 2>&1 | sed 's/^/        /'
    fi
    echo

    echo "PHP-FPM masters ($fpmFolder):"
    if test "$(fpm_versions)" = ""; then
        echo "  none, no instance is pinned"
    fi
    for version in $(fpm_versions); do
        if fpm_master_loaded $version; then
            ok "$version running ($(fpm_launch_label $version))"
        else
            warn "$version has pools but is not running, see $fpmFolder/$version/php-fpm.log"
        fi
        for pool in "$fpmFolder/$version/pools/"*.conf; do
            test -f "$pool" || continue
            set_target_instance $(basename "$pool" .conf)
            if ! test -d "$targetFolder"; then
                warn "pool $suffix has no instance folder $targetFolder (remove $pool)"
            elif test "$instancePhpVersion" != "$version"; then
                warn "pool $suffix runs PHP $version but .php-version says '${instancePhpVersion:-global}', run ps-php $suffix ${instancePhpVersion:-global}"
            fi
        done
    done
    echo

    echo "Instances (${baseFolder}*):"
    for folder in "$baseFolder"*; do
        test -d "$folder" || continue
        set_target_instance $(detect_suffix_from_path "$folder")
        vhostFile=/opt/homebrew/etc/httpd/extra/sites-enabled/$targetDomain.conf
        poolVersion=$(fpm_pool_version $suffix)
        if test "$instancePhpVersion" = ""; then
            pinned="global PHP"
        else
            pinned="PHP $instancePhpVersion"
        fi
        if test "$instancePhpVersion" != "" && test "$instancePhp" = ""; then
            warn "$suffix: $pinned is not installed"
            continue
        fi
        if test "$instancePhpVersion" != "" && test "$poolVersion" != "$instancePhpVersion"; then
            warn "$suffix: $pinned but no PHP-FPM $instancePhpVersion pool, run ps-php $suffix $instancePhpVersion"
            continue
        fi
        if ! test -f "$vhostFile"; then
            echo "  -     $suffix: $pinned, no vhost enabled"
            continue
        fi
        if ! vhost_php_up_to_date "$vhostFile"; then
            warn "$suffix: $pinned but the vhost PHP handler does not match, run ps-php $suffix ${instancePhpVersion:-global}"
            continue
        fi
        status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$targetUrl/")
        case "$status" in
            2*|3*) ok "$suffix: $pinned, HTTP $status" ;;
            *) warn "$suffix: $pinned, HTTP $status on $targetUrl/" ;;
        esac
    done
    echo

    if test $problems = 0; then
        echo "No problem found"
    else
        echo "$problems problem(s) found"
        return 1
    fi
}

if test "$1" = "doctor"; then
    source $BASEDIR/tools/tools.sh
    load_config
    doctor
    exit $?
fi
if test "$1" = "-h" || test "$1" = "--help" || test $# -gt 2; then
    usage
    exit 0
fi

# A single version argument: the suffix is detected from the current folder
target=""
if test $# = 2; then
    target=$2
    set -- $1
elif test $# = 1 && is_php_target "$1"; then
    target=$1
    set --
fi

source $BASEDIR/tools/config.sh

if ! test -d "$targetFolder"; then
    echo "No instance folder $targetFolder" >&2
    exit 1
fi

## Show

if test "$target" = ""; then
    if test "$instancePhpVersion" = ""; then
        echo "PHP:                global ($(php -r 'echo PHP_VERSION;' 2>/dev/null), PHP handler of httpd.conf for the web)"
    else
        echo "PHP:                $instancePhpVersion (.php-version)"
        echo "CLI:                ${instancePhp:-NOT INSTALLED}"
        echo "PHP-FPM pool:       $(fpm_pool_version $suffix | sed 's/^$/none/') ($(instance_fpm_socket))"
        echo "PHP error log:      $(instance_php_log)"
    fi
    echo "Installed versions: $(installed_php_versions | xargs)"
    exit 0
fi

if ! is_php_target "$target"; then
    echo "Invalid PHP version $target, expected <major>.<minor> or global" >&2
    exit 1
fi

## Switch

if test "$target" = "global"; then
    echo "Switching $suffix to the global PHP"
    disable_instance_fpm
    unpin_instance_php
else
    if ! php_fpm_binary_for_version "$target" > /dev/null; then
        echo "PHP $target with php-fpm is not installed (brew install php@$target), installed versions: $(installed_php_versions | xargs)" >&2
        exit 1
    fi
    if ! apache_has_proxy_fcgi; then
        print_apache_fpm_requirements
        exit 1
    fi
    echo "Switching $suffix to PHP $target"
    pin_instance_php "$target"
    enable_instance_fpm || exit 1
fi

# The vhost only changes when the instance goes from the global PHP to a pinned one or back
vhostFilePath="/opt/homebrew/etc/httpd/extra/sites-available/$targetDomain.conf"
if test -f "$vhostFilePath" && ! vhost_php_up_to_date "$vhostFilePath"; then
    echo "Updating the PHP handler of the vhost $vhostFilePath"
    write_vhost "$vhostFilePath"
    run_sudo "restart Apache to load the new PHP handler of $targetDomain" brew services restart httpd
fi

clear_cache

# Vendors installed with another PHP version may not run with this one
if test -f vendor/composer/platform_check.php && ! php vendor/composer/platform_check.php > /dev/null 2>&1; then
    echo "The vendors do not support PHP $(php -r 'echo PHP_VERSION;'), run composer install in $targetFolder" >&2
fi

status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$targetUrl/")
echo "$suffix: CLI PHP $(php -r 'echo PHP_VERSION;'), front office answers HTTP $status"
