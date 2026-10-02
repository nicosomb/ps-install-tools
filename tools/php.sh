#!/bin/sh
#
# PHP version per instance.
#
# An instance is pinned to a PHP version by a .php-version file at the root of its folder. The CLI
# then uses the binary of this version (use_instance_php) and the web is served by a PHP-FPM pool
# of this version, one pool per instance, run by PHP-FPM masters that belong to these tools:
#
#   <fpmFolder>/<version>/php-fpm.conf        master of the version, includes pools/*.conf
#   <fpmFolder>/<version>/pools/<suffix>.conf  pool of the instance
#   <fpmFolder>/sockets/<suffix>.sock          socket of the instance, used by its Apache vhost
#   ~/Library/LaunchAgents/<label>-<version>.plist  starts the master at login, no sudo
#
# Nothing of the Homebrew PHP config (php-fpm.d/www.conf, brew services) nor of httpd.conf is
# changed, each version keeps its own php.ini and extensions. Changing the version of an instance
# moves its pool from one master to the other: the socket, so the vhost, stays the same and Apache
# does not need a restart.

fpmLaunchLabel=com.prestashop.ps-install-tools.php-fpm

# Prints the Homebrew prefix (/opt/homebrew on Apple silicon, /usr/local on Intel)
brew_prefix() {
    if test "$HOMEBREW_PREFIX" != ""; then
        echo "$HOMEBREW_PREFIX"
    else
        brew --prefix 2>/dev/null || echo /opt/homebrew
    fi
}

# Prints the Homebrew folder of the PHP version given as argument (8.1, 8.4, ...), returns 1 when
# this version is not installed. The latest version may only be installed as the php formula (no
# php@X.Y folder), its folder is used when its version matches.
php_folder_for_version() {
    local prefix=$(brew_prefix)
    if test -x "$prefix/opt/php@$1/bin/php"; then
        echo "$prefix/opt/php@$1"
        return 0
    fi
    if test -x "$prefix/opt/php/bin/php" && test "$("$prefix/opt/php/bin/php" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')" = "$1"; then
        echo "$prefix/opt/php"
        return 0
    fi
    return 1
}

# Prints the path of the PHP binary of the version given as argument, returns 1 when not installed
php_binary_for_version() {
    local folder
    folder=$(php_folder_for_version "$1") || return 1
    echo "$folder/bin/php"
}

# Prints the path of the PHP-FPM binary of the version given as argument, returns 1 when missing
php_fpm_binary_for_version() {
    local folder
    folder=$(php_folder_for_version "$1") || return 1
    test -x "$folder/sbin/php-fpm" || return 1
    echo "$folder/sbin/php-fpm"
}

# Prints the installed PHP versions, one per line, oldest first
installed_php_versions() {
    local prefix=$(brew_prefix) folder version
    for folder in "$prefix"/opt/php@* "$prefix/opt/php"; do
        if test -x "$folder/bin/php"; then
            "$folder/bin/php" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION, "\n";' 2>/dev/null
        fi
    done | sort -t. -k1,1n -k2,2n -u
}

# Prints the PHP version (8.1, 8.4, ...) the instance folder given as argument is pinned to in its
# .php-version file, nothing when the instance uses the global PHP
get_instance_php_version() {
    if test -f "$1/.php-version"; then
        head -n 1 "$1/.php-version" | tr -d '[:space:]'
    fi
}

# Selects the PHP of the current instance, called by set_target_instance. When the instance folder
# has a .php-version file its PHP binary folder is put first in the PATH, so php, composer, the
# bin/console shebang and every sub process use this version. Otherwise the global PHP is kept.
# Sets instancePhpVersion (empty for the global PHP) and instancePhp (path of the binary, empty
# when the pinned version is not installed, see require_instance_php).
use_instance_php() {
    # Keep the PATH from before the first call, so successive instances do not stack their folders
    if test "$basePath" = ""; then
        basePath=$PATH
    fi
    PATH=$basePath
    instancePhpVersion=$(get_instance_php_version "$targetFolder")
    if test "$instancePhpVersion" = ""; then
        instancePhp=$(command -v php)
    else
        instancePhp=$(php_binary_for_version "$instancePhpVersion")
        if test "$instancePhp" != ""; then
            PATH="$(dirname "$instancePhp"):$PATH"
        fi
    fi
    export PATH
}

# Returns 1 with an error when the PHP version pinned by the instance is not installed, call it
# before running PHP for the instance
require_instance_php() {
    if test "$instancePhp" = ""; then
        echo "PHP $instancePhpVersion is required by $targetFolder/.php-version but is not installed (brew install php@$instancePhpVersion)" >&2
        return 1
    fi
}

# Writes the .php-version file of the current instance (version as argument) and selects it.
# The file is excluded from git locally so it never shows in git status of the PrestaShop clone.
pin_instance_php() {
    echo "$1" > "$targetFolder/.php-version"
    if test -d "$targetFolder/.git" && ! grep -qx '/.php-version' "$targetFolder/.git/info/exclude" 2>/dev/null; then
        mkdir -p "$targetFolder/.git/info"
        echo '/.php-version' >> "$targetFolder/.git/info/exclude"
    fi
    use_instance_php
}

# Removes the .php-version file of the current instance, it goes back to the global PHP
unpin_instance_php() {
    rm -f "$targetFolder/.php-version"
    use_instance_php
}

## PHP-FPM

# Prints the socket of the current instance
instance_fpm_socket() {
    echo "$fpmFolder/sockets/$suffix.sock"
}

# Prints the PHP error log of the current instance, next to its Apache logs
instance_php_log() {
    echo "$HOME/www/var/logs/prestashop-$suffix.php-error.log"
}

fpm_launch_label() {
    echo "$fpmLaunchLabel-$1"
}

fpm_launch_plist() {
    echo "$HOME/Library/LaunchAgents/$(fpm_launch_label "$1").plist"
}

# Returns 0 when the master of the version given as argument is loaded in launchd
fpm_master_loaded() {
    launchctl print "gui/$(id -u)/$(fpm_launch_label "$1")" > /dev/null 2>&1
}

# Prints the versions that have at least one pool in fpmFolder, one per line
fpm_versions() {
    local folder
    for folder in "$fpmFolder"/*/pools; do
        if ls "$folder/"*.conf > /dev/null 2>&1; then
            basename "$(dirname "$folder")"
        fi
    done
}

# Prints the version whose master serves the pool of the instance given as argument, nothing
# when no pool exists for it
fpm_pool_version() {
    local version
    for version in $(fpm_versions); do
        if test -f "$fpmFolder/$version/pools/$1.conf"; then
            echo "$version"
            return 0
        fi
    done
}

# Writes the master config and the LaunchAgent of the version given as argument
write_fpm_master() {
    local version=$1 fpmBinary
    fpmBinary=$(php_fpm_binary_for_version "$version") || {
        echo "No php-fpm binary for PHP $version (brew install php@$version)" >&2
        return 1
    }
    mkdir -p "$fpmFolder/$version/pools" "$fpmFolder/sockets" "$HOME/Library/LaunchAgents"
    cat > "$fpmFolder/$version/php-fpm.conf" <<EOM
; Generated by ps-install-tools, PHP-FPM master of PHP $version (pools of the instances in pools/)
[global]
pid = $fpmFolder/$version/php-fpm.pid
error_log = $fpmFolder/$version/php-fpm.log
daemonize = no
include = $fpmFolder/$version/pools/*.conf
EOM
    cat > "$(fpm_launch_plist "$version")" <<EOM
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(fpm_launch_label "$version")</string>
    <key>ProgramArguments</key>
    <array>
        <string>$fpmBinary</string>
        <string>--nodaemonize</string>
        <string>--fpm-config</string>
        <string>$fpmFolder/$version/php-fpm.conf</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$fpmFolder/$version/php-fpm.log</string>
</dict>
</plist>
EOM
}

# Writes the pool of the current instance in the master of the version given as argument
write_fpm_pool() {
    local version=$1
    mkdir -p "$fpmFolder/$version/pools" "$(dirname "$(instance_php_log)")"
    cat > "$fpmFolder/$version/pools/$suffix.conf" <<EOM
; Generated by ps-install-tools, PHP $version pool of the instance $suffix ($targetFolder)
[$suffix]
listen = $(instance_fpm_socket)
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 60s
; Same environment and logs as mod_php would give
clear_env = no
catch_workers_output = yes
php_admin_flag[log_errors] = on
php_admin_value[error_log] = $(instance_php_log)
EOM
}

# Starts, reloads or stops the master of the version given as argument according to its pools:
# a master refuses to start without any pool, so it is stopped and its LaunchAgent removed then
sync_fpm_master() {
    local version=$1 plist label
    plist=$(fpm_launch_plist "$version")
    label="gui/$(id -u)/$(fpm_launch_label "$version")"
    if ls "$fpmFolder/$version/pools/"*.conf > /dev/null 2>&1; then
        write_fpm_master "$version" || return 1
        if fpm_master_loaded "$version"; then
            echo "Reloading PHP-FPM $version"
            launchctl kill USR2 "$label"
        else
            echo "Starting PHP-FPM $version"
            launchctl bootstrap "gui/$(id -u)" "$plist"
        fi
    else
        if fpm_master_loaded "$version"; then
            echo "Stopping PHP-FPM $version (no instance left)"
            launchctl bootout "$label"
        fi
        rm -f "$plist"
    fi
}

# Waits until the socket of the current instance accepts connections (5 seconds at most)
wait_fpm_socket() {
    local socket=$(instance_fpm_socket) i=0
    while test $i -lt 50; do
        test -S "$socket" && return 0
        sleep 0.1
        i=$(($i+1))
    done
    echo "The socket $socket did not show up, see $fpmFolder/$instancePhpVersion/php-fpm.log" >&2
    return 1
}

# Waits until the previous master released the socket of the current instance (5 seconds at most)
wait_fpm_socket_gone() {
    local socket=$(instance_fpm_socket) i=0
    while test -S "$socket" && test $i -lt 50; do
        sleep 0.1
        i=$(($i+1))
    done
    rm -f "$socket"
}

# Serves the current instance with the PHP-FPM pool of its pinned version: moves the pool from
# the previous version if any, then syncs both masters
enable_instance_fpm() {
    local previousVersion
    previousVersion=$(fpm_pool_version "$suffix")
    # The previous master goes first: when it drops the pool it deletes the socket file, which
    # would be the one of the new master if it had started before
    if test "$previousVersion" != "" && test "$previousVersion" != "$instancePhpVersion"; then
        rm -f "$fpmFolder/$previousVersion/pools/$suffix.conf"
        sync_fpm_master "$previousVersion"
        wait_fpm_socket_gone
    fi
    write_fpm_pool "$instancePhpVersion"
    sync_fpm_master "$instancePhpVersion" || return 1
    wait_fpm_socket
}

# Removes the PHP-FPM pool of the current instance, whatever its version
disable_instance_fpm() {
    local previousVersion
    previousVersion=$(fpm_pool_version "$suffix")
    if test "$previousVersion" != ""; then
        echo "Removing PHP-FPM $previousVersion pool of $suffix"
        rm -f "$fpmFolder/$previousVersion/pools/$suffix.conf"
        sync_fpm_master "$previousVersion"
    fi
    rm -f "$(instance_fpm_socket)"
}

## Apache

# Prints the vhost lines sending the PHP files of the current instance to its PHP-FPM pool, nothing
# for an instance using the global PHP (the PHP handler of httpd.conf then applies, as before)
php_vhost_handler() {
    if test "$instancePhpVersion" = ""; then
        return
    fi
    # The socket path is the same whatever the version, so changing the version keeps the vhost
    cat <<EOM
    # PHP of the instance (.php-version), served by its ps-install-tools PHP-FPM pool
    <FilesMatch \.php$>
        SetHandler "proxy:unix:$(instance_fpm_socket)|fcgi://$suffix"
    </FilesMatch>
    # Long back office requests (module install, upgrade) go beyond the default 60 seconds
    ProxyTimeout 600
EOM
}

# Replaces the PHP handler of the vhost file given as argument by the one of the current instance,
# the other lines (domains changed by ps-ngrok for example) are kept
update_vhost_php_handler() {
    PHP_HANDLER="$(php_vhost_handler)" awk '
        /# PHP of the instance \(\.php-version\)/ { skip = 1 }
        skip { if (/ProxyTimeout/) skip = 0; next }
        /<\/VirtualHost>/ && ENVIRON["PHP_HANDLER"] != "" { print ENVIRON["PHP_HANDLER"] }
        { print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# Returns 0 when the vhost file given as argument matches the PHP of the current instance:
# it has the handler of its pool when it is pinned, it has none when it uses the global PHP
vhost_php_up_to_date() {
    if test "$instancePhpVersion" = ""; then
        ! grep -q "proxy:unix:" "$1"
    else
        grep -q "proxy:unix:$(instance_fpm_socket)|" "$1"
    fi
}

# Returns 0 when Apache loads mod_proxy_fcgi, required to serve an instance with PHP-FPM
apache_has_proxy_fcgi() {
    "$(brew_prefix)/bin/apachectl" -M 2>/dev/null | grep -q 'proxy_fcgi_module'
}

# Returns 1 with an error when the PHP version given as argument cannot serve an instance: invalid
# format, not installed with php-fpm, or Apache without mod_proxy_fcgi
check_php_requirements() {
    if ! echo "$1" | grep -qE '^[0-9]+\.[0-9]+$'; then
        echo "Invalid PHP version $1, expected <major>.<minor> (use ps-php <suffix> global to go back to the global PHP)" >&2
        return 1
    fi
    if ! php_fpm_binary_for_version "$1" > /dev/null; then
        echo "PHP $1 with php-fpm is not installed (brew install php@$1), installed versions: $(installed_php_versions | xargs)" >&2
        return 1
    fi
    if ! apache_has_proxy_fcgi; then
        print_apache_fpm_requirements
        return 1
    fi
}

# Prints what to do when mod_proxy_fcgi is missing
print_apache_fpm_requirements() {
    cat >&2 <<EOM
Apache does not load mod_proxy_fcgi, it is needed to serve an instance with its own PHP version.
Uncomment these lines in $(brew_prefix)/etc/httpd/httpd.conf and restart Apache:
    LoadModule proxy_module lib/httpd/modules/mod_proxy.so
    LoadModule proxy_fcgi_module lib/httpd/modules/mod_proxy_fcgi.so
mod_php (if you use it) can stay loaded: instances without .php-version keep using it. Check that
the global PHP handler of your httpd.conf does not change when proxy_fcgi_module is loaded
(an <IfModule proxy_fcgi_module> block for example), then run ps-php doctor.
EOM
}
