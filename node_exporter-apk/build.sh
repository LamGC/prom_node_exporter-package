#!/bin/bash

###########################################
# Build script for prometheus-node-exporter Alpine APK package.
# Downloads a pre-compiled node_exporter binary from upstream GitHub
# releases and wraps it in an .apk package using abuild.
###########################################
project='prometheus'
product='node_exporter'
pkg_name='prometheus-node-exporter'
pkg_version='latest'
pkg_release='0'
isDebug=false
target_arch=''
current_dir=$(dirname "$(readlink -f "$0")")
build_root=$(realpath "$current_dir/build")
download_url_root="https://github.com/$project/$product/releases/download/"
release_link="https://api.github.com/repos/$project/$product/releases"
execute_features=()
declare -A available_versions

# Dependency binaries and the Alpine packages that provide them.
declare -A deps_bin_to_pkg
deps_bin_to_pkg=(
    ['wget']='wget'
    ['curl']='curl'
    ['abuild']='abuild'
    ['abuild-keygen']='abuild'
    ['abuild-sign']='abuild'
)

# Mapping from Alpine arch to upstream Go arch suffix.
declare -A ARCH_MAP
ARCH_MAP=(
    ['x86_64']='amd64'
    ['aarch64']='arm64'
    ['armv7']='armv7'
    ['x86']='386'
    ['s390x']='s390x'
    ['ppc64le']='ppc64le'
    ['riscv64']='riscv64'
)

# CBUILD triplet — must use GCC/musl target triplet conventions, NOT
# Alpine APKBUILD arch names.  abuild's hostspec_to_arch() matches the
# CPU component with patterns like i[0-9]86, powerpc64le, armv7*-eabihf
# and returns "unknown" for unrecognised triples (line 2769 of abuild).
declare -A TRIPLET_MAP
TRIPLET_MAP=(
    ['x86_64']='x86_64-alpine-linux-musl'
    ['aarch64']='aarch64-alpine-linux-musl'
    ['armv7']='armv7-alpine-linux-musleabihf'
    ['x86']='i586-alpine-linux-musl'
    ['s390x']='s390x-alpine-linux-musl'
    ['ppc64le']='powerpc64le-alpine-linux-musl'
    ['riscv64']='riscv64-alpine-linux-musl'
)

function alpine_triplet()
{
    local t="${TRIPLET_MAP[$target_arch]}"
    if [ -z "$t" ]; then
        echo "ERROR: Unknown Alpine architecture: $target_arch" >&2
        echo "Supported: ${!TRIPLET_MAP[*]}" >&2
        exit 15
    fi
    echo "$t"
}

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
function sort_versions()
{
    # Sort version numbers in descending order.
    # Uses -t. -k for BusyBox compatibility (no --version-sort).
    sort -t. -k1,1nr -k2,2nr -k3,3nr 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n
}
function print_debug_line()
{
    if [ "$isDebug" = true ]; then
        printf "DEBUG: $1\n"
    fi
}

function usage()
{
    echo "Script to download and package $product as an Alpine .apk."
    echo "The script should _NOT_ be run as root. It will ask for"
    echo "password via sudo if something needs it."
    echo ""
    echo "Usage: ${0} [-v version_to_build] [-r release_version] [-a arch] [-b build_root]"
    echo -e "\n-v\tVersion of $product to build. This version should be"
    echo -e "  \tavailable upstream. Default: latest ($pkg_version)"
    echo -e "\n-r\tAlpine package release number. Use this field to specify"
    echo -e "  \ta custom release (e.g. \"0\", \"1\")."
    echo -e "  \tDefault: 0"
    echo -e "\n-a\tTarget Alpine architecture (e.g. x86_64, aarch64, armv7,"
    echo -e "  \tx86, s390x, ppc64le, riscv64)."
    echo -e "  \tDefault: auto-detect (via \$(uname -m) or first known arch)"
    echo -e "\n-b\tPath for build output. Default: ./build"
    echo -e "\n-l\tList available versions."
    echo -e "\n-h\tShow this help message and exit."
    echo -e "\n-d\tPrint debugging statements."
    echo -e "\nExample: ${0} -v $pkg_version"
    echo -e "         ${0} -v 1.11.1 -a aarch64"
}

function parse_command()
{
    SHORT=v:r:a:b:lhd
    LONG=version:,release:,arch:,build_root:,list,help,debug
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
            -a|--arch)
                target_arch="$2"
                shift 2
                ;;
            -b|--build_root)
                build_root="$2"
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

function resolve_arch()
{
    if [ -z "$target_arch" ]; then
        local host
        host=$(uname -m)
        case "$host" in
            x86_64)    target_arch="x86_64" ;;
            aarch64)   target_arch="aarch64" ;;
            armv7l)    target_arch="armv7" ;;
            armv6l)    target_arch="armhf" ;;
            i686|i386) target_arch="x86" ;;
            s390x)     target_arch="s390x" ;;
            ppc64le)   target_arch="ppc64le" ;;
            riscv64)   target_arch="riscv64" ;;
            *)
                echo "WARNING: Unknown host arch '$host', defaulting to x86_64"
                target_arch="x86_64"
                ;;
        esac
    fi
    print_debug_line "Target architecture: $target_arch (Go: $(go_arch))"
}

function perform_safety_checks()
{
    # Ensure we are not running as root.
    if [ $EUID -eq 0 ]; then
        echo 'Please do not run this script as root.'
        exit 3
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
        if [ -f /sbin/apk ]; then
            echo -e "\nFollowing packages need to be installed:\n$unavailable_packages"
            echo "Please enter the password for sudo (if prompted)"
            sudo apk add $unavailable_packages

            if [ "$?" -ne 0 ]; then
                echo -e "\nSome packages could not be installed successfully."
                echo "Please debug and rerun the script."
                exit 5
            fi
        else
            echo -e "\nMissing dependencies: $unavailable_packages"
            echo "This does not appear to be an Alpine system."
            echo "Please install the packages manually or run inside an Alpine container."
            exit 5
        fi
    fi

    # Check that the user is in the abuild group.
    if ! groups | grep -q abuild; then
        echo "WARNING: You are not in the 'abuild' group."
        echo "Build may fail. Run: sudo addgroup \$USER abuild"
    fi

    # Generate signing keys if missing.
    if [ ! -f "$HOME/.abuild/abuild.conf" ] || [ ! -f "$HOME/.abuild/"*.rsa ]; then
        print_debug_line "Setting up abuild signing keys..."
        abuild-keygen -a -i -n 2>/dev/null || {
            echo "WARNING: Could not generate abuild keys."
            echo "Try: sudo apk add abuild && abuild-keygen -a -i"
        }
    fi
}

function validate_inputs()
{
    [ ${#available_versions[@]} -eq 0 ] && get_available_versions

    is_version_valid='false'
    if [ "$pkg_version" == "latest" ]; then
        pkg_version=$(echo ${!available_versions[@]} | tr ' ' '\n' | sort_versions | tail -n 1)
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

    # pkg_release must be a non-negative integer (Alpine convention).
    if ! [[ "$pkg_release" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Release number '$pkg_release' must be a non-negative integer."
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
    # Build auth array safely to avoid word-splitting.
    local curl_auth=()
    [ -n "$GITHUB_TOKEN" ] && curl_auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    # Use grep -E (POSIX ERE) instead of -P (Perl) for Alpine/BusyBox compat.
    links=$(curl --silent "${curl_auth[@]}" "$release_link" | grep -oE "https.+$product-[0-9]+\.[0-9]+\.[0-9]+\.linux-${_go_arch}.tar.gz")
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
    echo ${!available_versions[@]} | tr -s ' ' '\n' | sort_versions -r
}

function setup_build_dir()
{
    # Safety: validate build_root is a safe subdirectory of this project.
    if [ -z "$build_root" ]; then
        echo "ERROR: build_root is empty." >&2
        exit 13
    fi

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

    # Copy APKBUILD template and companion files to build root.
    print_debug_line "${FUNCNAME[0]} : Copying packaging files to $build_root."
    cp "$current_dir/APKBUILD.in" "$build_root/APKBUILD.in"
    cp "$current_dir/node-exporter.initd" "$build_root/"
    cp "$current_dir/node-exporter.confd" "$build_root/"
    cp "$current_dir/prometheus-node-exporter.pre-install" "$build_root/"
    cp "$current_dir/prometheus-node-exporter.post-upgrade" "$build_root/"

    # Generate APKBUILD from template.
    print_debug_line "${FUNCNAME[0]} : Generating APKBUILD for version=$pkg_version arch=$target_arch"
    sed -e "s/__VERSION__/$pkg_version/g" \
        -e "s/__RELEASE__/$pkg_release/g" \
        -e "s/__ARCH__/$target_arch/g" \
        "$build_root/APKBUILD.in" > "$build_root/APKBUILD"
    rm "$build_root/APKBUILD.in"

    # Copy LICENSE.
    local license_path="$current_dir/../LICENSE"
    if [ -f "$license_path" ]; then
        cp "$license_path" "$build_root/"
    fi
}

function download_and_extract()
{
    core_archive_name=$(basename "${available_versions[$pkg_version]}")
    failed_download='false'

    if [ -f "$build_root/$core_archive_name" ]; then
        print_debug_line "$build_root/$core_archive_name already exists. Not downloading again..."
    else
        local wget_auth=()
        [ -n "$GITHUB_TOKEN" ] && wget_auth=(--header="Authorization: Bearer $GITHUB_TOKEN")
        print_debug_line "${FUNCNAME[0]} : Downloading ${available_versions[$pkg_version]} to $build_root/$core_archive_name"
        wget "${wget_auth[@]}" -O "$build_root/$core_archive_name" "${available_versions[$pkg_version]}"
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

    echo "SHA256 ($core_archive_name) = $(sha256sum "$build_root/$core_archive_name" | cut -d' ' -f1)"
}

function compute_checksums()
{
    print_debug_line "${FUNCNAME[0]} : Computing sha512 checksums."

    cd "$build_root"

    # Build the source= array and sha512sums= block for the APKBUILD.
    # abuild needs these to verify files. We compute them after the tarball
    # is downloaded so we can include the source archive checksum.
    local source_files=()
    local checksum_lines=()

    # The tarball is the primary source (if present).
    local tarball_name
    tarball_name=$(basename "${available_versions[$pkg_version]}")
    if [ -f "$tarball_name" ]; then
        source_files+=("$tarball_name")
        local chk
        chk=$(sha512sum "$tarball_name" | awk '{print $1}')
        checksum_lines+=("$chk  $tarball_name")
    fi

    # The local files (install scripts are NOT listed in source= — abuild
    # auto-detects them by naming convention and warns if they're in source).
    for f in node-exporter.initd node-exporter.confd; do
        source_files+=("$f")
        local chk
        chk=$(sha512sum "$f" | awk '{print $1}')
        checksum_lines+=("$chk  $f")
    done

    # Write source= line into APKBUILD.
    sed -i "/^source=/c\source=\"${source_files[*]}\"" APKBUILD

    # Append sha512sums.
    {
        echo 'sha512sums="'
        for line in "${checksum_lines[@]}"; do
            echo "$line"
        done
        echo '"'
    } >> APKBUILD

    cd - > /dev/null
}

function build_package()
{
    print_debug_line "${FUNCNAME[0]} : Building .apk package (arch: $target_arch)."

    cd "$build_root"

    # abuild requires a writable ~/.abuild for config and keys.
    export ABUILD_USERDIR="${HOME}/.abuild"

    # For cross-architecture builds (e.g., aarch64 on x86_64), abuild
    # validates CBUILD/CHOST/CTARGET against its known-arch list.
    # We use the same arch name as the APKBUILD arch= field.
    local triplet
    triplet=$(alpine_triplet) || exit 15
    export CBUILD="$triplet"
    export CHOST="$triplet"
    export CTARGET="$triplet"

    # Run abuild to build the package.
    # -F : force — skip checksum re-verification.
    # -d : skip dependency resolution (no build deps needed).
    abuild -F -d 2>&1

    if [ "$?" -ne 0 ]; then
        echo "ERROR: abuild failed."
        exit 10
    fi

    cd - > /dev/null

    echo ""
    echo "============================================================================="
    echo "Build successful!"
    echo "Package(s) created:"
    find ~/packages -name "${pkg_name}*.apk" -newer "$build_root/APKBUILD" -type f 2>/dev/null | while read -r apk; do
        ls -la "$apk"
    done
    echo "============================================================================="
}

##################
# Main
parse_command "$@"
resolve_arch
perform_safety_checks
validate_inputs

# Execute features (list, help) and exit.
for func in "${execute_features[@]}"; do
    $func
done
[ ${#execute_features[@]} -gt 0 ] && exit 0

print_debug_line "Build target: version=$pkg_version release=$pkg_release arch=$target_arch go_arch=$(go_arch)"
setup_build_dir
download_and_extract
compute_checksums
build_package
