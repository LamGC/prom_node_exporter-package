#!/bin/bash

###########################################
# Build script for prometheus-node-exporter Debian package.
# Downloads a pre-compiled node_exporter binary from upstream GitHub
# releases and wraps it in a .deb package.
###########################################
project='prometheus'
product='node_exporter'
pkg_name='prometheus-node-exporter'
pkg_version='latest'
pkg_release='1'
isDebug=false
target_arch=''
current_dir=$(dirname "$(readlink -f "$0")")
build_root=$(realpath "$current_dir/build")
download_url_root="https://github.com/$project/$product/releases/download/"
release_link="https://api.github.com/repos/$project/$product/releases"
maybe_login_to_github=${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"}
maybe_login_to_github_wget=${GITHUB_TOKEN:+--header="Authorization: Bearer $GITHUB_TOKEN"}
execute_features=()
declare -A available_versions

# Dependency binaries and the Debian packages that provide them.
declare -A deps_bin_to_pkg
deps_bin_to_pkg=(
    ['wget']='wget'
    ['curl']='curl'
    ['dpkg-buildpackage']='dpkg-dev'
    ['fakeroot']='fakeroot'
    ['dch']='devscripts'
    ['dh']='debhelper'
)

# Mapping from Debian dpkg architecture to Go upstream arch suffix.
declare -A ARCH_MAP
ARCH_MAP=(
    ['amd64']='amd64'
    ['arm64']='arm64'
    ['armhf']='armv7'
    ['i386']='386'
    ['ppc64el']='ppc64le'
    ['s390x']='s390x'
    ['riscv64']='riscv64'
    ['mips64el']='mips64le'
)

function go_arch()
{
    local go="${ARCH_MAP[$target_arch]}"
    if [ -z "$go" ]; then
        echo "ERROR: Unsupported architecture: $target_arch" >&2
        echo "Supported: ${!ARCH_MAP[*]}" >&2
        exit 11
    fi
    echo "$go"
}
###########################################
# Functions                               #
###########################################
function print_debug_line()
{
    if [ "$isDebug" = true ]; then
        printf "DEBUG: $1\n"
    fi
}

function usage()
{
    echo "Script to download and package $product as a .deb."
    echo "The script should _NOT_ be run as root. It will ask for"
    echo "password via sudo if something needs it."
    echo ""
    echo "Usage: ${0} [-v version_to_build] [-r release_version] [-b build_root]"
    echo -e "\n-v\tVersion of $product to build. This version should be"
    echo -e "  \tavailable upstream. Default: latest ($pkg_version)"
    echo -e "\n-r\tDebian package release version. Use this field to specify"
    echo -e "  \tif this is a custom version (e.g. \"1mycompany\")."
    echo -e "  \tDefault: 1"
    echo -e "\n-b\tPath for build output. Default: ./build"
    echo -e "\n-a\tTarget Debian architecture (e.g. amd64, arm64, armhf,"
    echo -e "  \ti386, ppc64el, s390x, riscv64, mips64el)."
    echo -e "  \tDefault: auto-detect ($target_arch)"
    echo -e "\n-l\tList available versions."
    echo -e "\n-h\tShow this help message and exit."
    echo -e "\n-d\tPrint debugging statements."
    echo -e "\nExample: ${0} -v $pkg_version"
    echo -e "         ${0} -v 1.11.1 -a arm64"
}

function parse_command()
{
    SHORT=v:r:b:a:lhd
    LONG=version:,release:,build_root:,arch:,list,help,debug
    PARSED=$(getopt --options $SHORT --longoptions $LONG --name "$0" -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -d|--debug)
                isDebug=true;
                print_debug_line "ON";
                shift
                ;;
            -v|--version)
                pkg_version="$2"
                shift 2
                ;;
            -r|--release)
                pkg_release="$2"
                shift 2
                ;;
            -b|--build_root)
                build_root="$2"
                shift 2
                ;;
            -a|--arch)
                target_arch="$2"
                shift 2
                ;;
            -l|--list)
                execute_features+=('print_available_versions')
                shift
                ;;
            -h|--help)
                execute_features+=('usage')
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                echo -e "\nProgrammer has the dumbz."
                exit 2
                ;;
        esac
    done
}

function perform_safety_checks()
{
    # Ensure we are not running as root.
    if [ $EUID -eq 0 ]; then
        echo 'Please do not run this script as root.'
        exit 3
    fi

    # Ensure we are on Debian or Ubuntu.
    is_debian=false
    if [ -f "/etc/debian_version" ]; then
        is_debian=true
        print_debug_line "${FUNCNAME[0]} : Debian/Ubuntu detected."
    elif [ -f "/proc/version" ]; then
        proc_version=$(cat /proc/version)
    else
        proc_version=$(uname -a)
    fi

    if [ "$is_debian" != true ]; then
        if [[ "$proc_version" != *"Debian"* ]] && [[ "$proc_version" != *"Ubuntu"* ]]; then
            echo "WARNING: Your OS does not appear to be Debian or Ubuntu."
            echo "The .deb may not work correctly on this system."
        fi
    fi

    # Check if required packages are installed.
    unavailable_packages=''
    for dep in ${!deps_bin_to_pkg[@]}; do
        which $dep &>/dev/null
        if [ "$?" -gt 0 ]; then
            print_debug_line "${FUNCNAME[0]} : '$dep' from '${deps_bin_to_pkg[$dep]}' is not installed."
            unavailable_packages+="${deps_bin_to_pkg[$dep]} "
        fi
        print_debug_line "${FUNCNAME[0]} : $dep is available."
    done

    if [ -n "$unavailable_packages" ]; then
        echo -e "\nFollowing packages need to be installed:\n$unavailable_packages"
        echo "Please enter the password for sudo (if prompted)"
        sudo apt-get update -qq && sudo apt-get install -y $unavailable_packages

        if [ "$?" -ne 0 ]; then
            echo -e "\nSome packages could not be installed successfully. Following command was run:"
            echo -e "sudo apt-get install -y $unavailable_packages"
            echo -e "\nPlease debug and rerun the script."
            exit 5
        fi
    fi

    # Detect target architecture now that dpkg-dev is installed.
    if [ -z "$target_arch" ]; then
        target_arch=$(dpkg-architecture -q DEB_HOST_ARCH 2>/dev/null || echo "amd64")
    fi
    print_debug_line "${FUNCNAME[0]} : target architecture: $target_arch"
}

function validate_inputs()
{
    [ ${#available_versions[@]} -eq 0 ] && get_available_versions

    is_version_valid='false'
    if [ "$pkg_version" == "latest" ]; then
        pkg_version=$(echo ${!available_versions[@]} | tr ' ' '\n' | sort --version-sort | tail -n 1)
        is_version_valid='true'
    else
        for available_version in ${!available_versions[@]}; do
            if [ "$available_version" == "$pkg_version" ]; then
                is_version_valid='true'
                break
            fi
        done
    fi

    if [ "$is_version_valid" == 'false' ]; then
        echo "'$pkg_version' of $product is not available upstream. Versions available for packaging:"
        print_available_versions
        exit 6
    fi

    # pkg_release must only contain safe characters (Debian version policy §5.6.12).
    if ! [[ "$pkg_release" =~ ^[a-zA-Z0-9.+~-]+$ ]]; then
        echo "ERROR: Release string '$pkg_release' contains invalid characters."
        echo "Allowed: alphanumeric, dot, plus, tilde, hyphen."
        exit 12
    fi

    print_debug_line "Using version: $pkg_version"
    print_debug_line "Using release: $pkg_release"
}

function get_available_versions()
{
    local _go_arch
    _go_arch=$(go_arch) || exit 11

    print_debug_line "Getting available versions from $release_link (arch: $_go_arch)"
    links=$(curl --silent ${maybe_login_to_github:+"$maybe_login_to_github"} "$release_link" | grep -oP "https.+$product-\d+\.\d+\.\d+\.linux-${_go_arch}.tar.gz")
    if [ "$?" -ne 0 ]; then
        echo "Could not fetch releases from $release_link."
        echo "Please verify you are connected to the interwebz."
        echo "Exiting..."
        exit 7
    fi
    for link in $links; do
        ver=$(echo "$link" | cut -f 8 -d '/' | tr -d 'v')
        available_versions["$ver"]=$link
    done
}

function print_available_versions()
{
    echo "Released versions available upstream..."
    [ ${#available_versions[@]} -eq 0 ] && get_available_versions
    echo ${!available_versions[@]} | tr -s ' ' '\n' | sort --version-sort --reverse
}

function setup_build_dir()
{
    # Safety: validate build_root is a safe subdirectory of this project.
    if [ -z "$build_root" ]; then
        echo "ERROR: build_root is empty." >&2
        exit 13
    fi

    # Resolve to an absolute path for safe comparison.
    mkdir -p "$build_root" || {
        echo "ERROR: Cannot create build_root: $build_root" >&2
        exit 13
    }
    build_root=$(realpath "$build_root")

    local safe_prefix
    safe_prefix=$(realpath "$current_dir")
    if [[ "$build_root" != "$safe_prefix"/* ]] && [[ "$build_root" != "$safe_prefix" ]]; then
        echo "ERROR: build_root must be under $safe_prefix" >&2
        echo "Got: $build_root" >&2
        exit 13
    fi

    print_debug_line "${FUNCNAME[0]} : Cleaning and recreating build directory."
    rm -rf "$build_root"
    mkdir -p "$build_root"

    # Copy debian/ directory into build root.
    print_debug_line "${FUNCNAME[0]} : Copying debian/ to $build_root."
    cp -R "$current_dir/debian" "$build_root/"

    # Copy LICENSE for dh_installdocs (must exist at repo root).
    local license_path="$current_dir/../LICENSE"
    if [ ! -f "$license_path" ]; then
        echo "ERROR: LICENSE not found at $license_path" >&2
        exit 14
    fi
    cp "$license_path" "$build_root/"
}

function download_and_extract()
{
    core_archive_name=$(basename "${available_versions[$pkg_version]}")
    failed_download='false'

    if [ -f "$build_root/$core_archive_name" ]; then
        print_debug_line "$build_root/$core_archive_name already exists. Not downloading again..."
    else
        print_debug_line "${FUNCNAME[0]} : Downloading ${available_versions[$pkg_version]} to $build_root/$core_archive_name"
        wget ${maybe_login_to_github_wget} -O "$build_root/$core_archive_name" "${available_versions[$pkg_version]}"
        wget_exit=$?

        if [ ! -s "$build_root/$core_archive_name" ] || [ "$wget_exit" -ne 0 ]; then
            echo
            echo "Failed to download ${available_versions[$pkg_version]}."
            echo "Please verify if the link is accurate and network connectivity"
            echo "is available."
            failed_download='true'
        fi
    fi

    if [ "$failed_download" == 'true' ]; then
        echo -e "\nDownload(s) failed :(. Exiting.\n"
        exit 8
    fi

    # Extract the binary from the tarball.
    print_debug_line "${FUNCNAME[0]} : Extracting node_exporter binary."
    tar -xzf "$build_root/$core_archive_name" -C "$build_root" \
        --strip-components=1 \
        "$(basename "$core_archive_name" .tar.gz)/node_exporter"

    if [ ! -f "$build_root/node_exporter" ]; then
        echo "ERROR: Failed to extract node_exporter binary."
        exit 9
    fi

    print_debug_line "${FUNCNAME[0]} : Binary extracted to $build_root/node_exporter"
}

function update_changelog()
{
    local version_string="$pkg_version-$pkg_release"
    print_debug_line "${FUNCNAME[0]} : Updating changelog to version $version_string"

    cd "$build_root"
    # Use sed instead of dch to avoid interactive prompts.
    sed -i "1s/(.*)/(${version_string})/" debian/changelog
    # Update the trailer date to the current time.
    local now
    now=$(date -R)
    sed -i "s/^ -- .*/ -- prom_node_exporter package maintainer <package@example.com>  $now/" debian/changelog
    cd - > /dev/null
}

function build_package()
{
    print_debug_line "${FUNCNAME[0]} : Building .deb package (arch: $target_arch)."

    cd "$build_root"
    dpkg-buildpackage -b -us -uc -d -a"$target_arch"

    if [ "$?" -ne 0 ]; then
        echo "ERROR: dpkg-buildpackage failed."
        exit 10
    fi
    cd - > /dev/null

    echo ""
    echo "============================================================================="
    echo "Build successful!"
    echo "Package(s) created:"
    ls -la "$(dirname "$build_root")"/${pkg_name}_*.deb 2>/dev/null || \
        ls -la "$build_root"/../${pkg_name}_*.deb 2>/dev/null
    echo "============================================================================="
}

##################
# Main
parse_command "$@"
perform_safety_checks
validate_inputs

# Execute features (list, help) and exit.
for func in "${execute_features[@]}"; do
    $func
done
[ ${#execute_features[@]} -gt 0 ] && exit 0

_go_arch=$(go_arch) || exit 11
print_debug_line "Build target: version=$pkg_version release=$pkg_release arch=$target_arch go_arch=$_go_arch"
setup_build_dir
download_and_extract
update_changelog
build_package
