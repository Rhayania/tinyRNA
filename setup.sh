#!/usr/bin/env bash

# USAGE: if you would like to install under a different conda environment name,
# you can pass the preferred name as the first argument to the script:
#   ./setup.sh preferred_name

env_name=${1:-tinyrna}
miniconda_version="25.1.1-2"
cwd="$(dirname "$0")"
export ts=$(date +%Y-%m-%d_%H-%M-%S) && readonly ts

# This is the default Python version that will be used by Miniconda (if installation of Miniconda is required).
# Note that this isn't the same as the tinyRNA environment's Python version.
# The tinyRNA environment's Python version is instead specified in the platform lockfile.
miniconda_python_version="310"


######------------------------------ HELPER FUNCTIONS -------------------------------######


function success() {
  local check="✓"
  local green_on="\033[1;32m"
  local green_off="\033[0m"
  printf "${green_on}${check} %s${green_off}\n" "$*"
}

function status() {
  local blue_on="\033[1;34m"
  local blue_off="\033[0m"
  printf "${blue_on}%s${blue_off}\n" "$*"
}

function warn() {
  local exclaim="⚠"
  local yellow_on="\033[1;33m"
  local yellow_off="\033[0m"
  printf "${yellow_on}${exclaim} %s${yellow_off}\n" "$*"
}

function fail() {
  local nope="⃠"
  local red_on="\033[1;31m"
  local red_off="\033[0m"
  printf "${red_on}${nope} %s${red_off}\n" "$*"
}

function stop() {
  kill -TERM -$$
}
# Ensures that when user presses Ctrl+C, the script stops
# rather than stopping current task and proceeding to the next
trap 'stop' SIGINT

function get_host_conda_command() {
  if command -v conda > /dev/null 2>&1; then
    echo "conda"
  elif command -v mamba > /dev/null 2>&1; then
    echo "mamba"
  elif command -v micromamba > /dev/null 2>&1; then
    echo "micromamba"
  else
    return 1  # installation is required
  fi
}

function get_shell_rcfile() {
  local shell="$1"
  local os="$2"
  case $shell in
    bash)
      # see https://github.com/conda/conda/pull/11849
      if [[ $os == "macOS" ]]; then
        echo "${HOME}/.bash_profile"
      else
        echo "${HOME}/.bashrc"
      fi;;
    zsh)  # |xonsh|tcsh)
      echo "${HOME}/.${shell}rc";;
    # fish)
    #   echo "${HOME}/.config/fish/config.fish";;
    # nu)
    #   echo "${HOME}/.config/nushell/config.nu";;
    *)
      return 1  # shell isn't supported
  esac
}

function get_shell_hook() {
  local shell_current="$1"
  if [[ $CONDA == "conda" ]]; then
    $CONDA shell."$shell_current" hook
  elif [[ $CONDA == "mamba" || $CONDA == "micromamba" ]]; then
    $CONDA shell hook -s "$shell_current"
  fi
}

function get_init_block_regex() {
  if [[ $CONDA == "conda" ]]; then
    echo '/^# >>> conda initialize >>>/,/^# <<< conda initialize <<</p'
  elif [[ $CONDA == "mamba" || $CONDA == "micromamba" ]]; then
    echo '/^# >>> mamba initialize >>>/,/^# <<< mamba initialize <<</p'
  fi
}

function download_and_install_miniconda() {
  local miniconda_installer="$1"
  status "Downloading Miniconda..."
  curl -O -# "https://repo.anaconda.com/miniconda/${miniconda_installer}"
  if [ -f "$miniconda_installer" ]; then
    success "Miniconda downloaded"
    if ! verify_miniconda_checksum "$miniconda_installer"; then
      fail "Miniconda checksum verification failed"
      stop
    fi
    status "Running interactive Miniconda installer..."
    # Use bash since the installer appears to no longer work with zsh
    if ! bash "$miniconda_installer"; then
      fail "Miniconda installation failed"
      stop
    fi
  else
    fail "Miniconda download failed"
    stop
  fi
}

function verify_miniconda_checksum() {
  local installer_file; local repo_index; local installer_hash; local expected_hash;

  installer_file="$1"
  if ! installer_hash=$(set -o pipefail && shasum -a 256 "$installer_file" | cut -f 1 -d ' '); then
    fail "Failed to get checksum for Miniconda installer"
    return 1
  fi

  # Get HTML table of all Miniconda versions and their info, including checksums
  if ! repo_index=$(curl -s https://repo.anaconda.com/miniconda/ 2> /dev/null); then
    fail "Failed to download the list of Miniconda installer checksums"
    return 1
  fi

  # Parse installer's expected hash from the table
  expected_hash=$(awk -v target="$installer_file" \
    'BEGIN { FS = "</?td\.*>"; RS = "</?tr>" }
    NF==8 && index($2, target) { print $7; exit; }' \
    <<< "$repo_index")

  if [[ "$installer_hash" == "$expected_hash" ]]; then
    success "Miniconda installer checksum verified"
  elif $GREP -q "$installer_hash" <<< "$repo_index"; then
    # Fallback incase table HTML changes in the future
    success "Miniconda installer checksum verified (fallback)"
  else
    fail "SHA256 checksum for $installer_file"
    fail "Expected: $expected_hash"
    fail "Actual:   $installer_hash"
    rm "$installer_file"
    return 1
  fi
}

## This function attempts to normalize formatting variations in the `env list` output
## across different Conda/Mamba versions so that it's easier to handle downstream.
## The output is two tab separated columns: env name (can be zero width) and path.
function get_env_list() {
  local env_list; local names_width;

  env_list=$($CONDA env list)

  # Heuristic to determine name column width
  names_width=$(echo "$env_list" | awk '
    {
      path_start_pos = index($0, "/");
      if (path_start_pos) count[path_start_pos]++;
    }
    END {
      for (pos in count) {
        if (count[pos] > max_count) {
          max_count = count[pos];
          width = pos;
        }
      }
      print width;
    }'
  )

  # Extract columns and normalize formatting
  echo "$env_list" | awk -v f1="$names_width" '
    substr($0, f1, 1) == "/" {
      name = substr($0, 1, f1 - 1);
      gsub(/(^[[:space:]]+)|(([[:space:]]|\*)+)/, "", name);
      path = substr($0, f1);
      print name "\t" path;
    }'
}

function remove_environment() {
  local env_name="$1"
  local logfile="env_remove_${ts}.log"

  status "Removing $env_name environment..."
  if ! $CONDA env remove -n "$env_name" -y > "$logfile" 2>&1; then
    fail "Failed to remove environment (see ${logfile})"
    stop
  else
    success "$env_name environment removed"
  fi
}

function setup_environment() {
  local env_name="$1"
  local platform_lockfile="$2"
  local logfile="env_install_${ts}.log"

  # Setup tinyRNA environment using our generated lock file
  status "Setting up $env_name environment (this may take a while)..."
  $CONDA create --file "$platform_lockfile" --name "$env_name" -y > "$logfile" 2>&1

  # Check that the new environment is listed
  if ! get_env_list | $GREP -q "^${env_name}\t/"; then
    fail "$env_name environment setup failed (see ${logfile})"
    stop
  else
    success "$env_name environment setup complete"
  fi
}

function setup_macOS_command_line_tools() {
  # Install Xcode command line tools if necessary
  if ! xcode-select --print-path > /dev/null 2>&1; then
    status "Installing Xcode command line tools. Follow prompts in new window..."
    if xcode-select --install; then
      success "Command line tools setup complete"
    else
      fail "Command line tools installation failed"
      stop
    fi
  else
    success "Xcode command line tools are already installed"
  fi
}


######--------------------------------- PRECHECKS -----------------------------------######


if [[ $CONDA_DEFAULT_ENV == "$env_name" ]]; then
    fail "You must deactivate the $env_name environment before running this script"
    exit 1
fi


######--------------------------------- HOST INFO -----------------------------------######

if [[ "$OSTYPE" == "darwin"* ]]; then
  platform="macOS"
  arch=$(uname -m)  # Support Apple Silicon
  echo $arch
  shell_preferred=$(basename "$(dscl . -read ~/ UserShell | cut -f 2 -d " ")")
  miniconda_installer="Miniconda3-py${miniconda_python_version}_${miniconda_version}-MacOSX-${arch}.sh"
  platform_lockfile="${cwd}/conda/conda-osx-64.lock"
  setup_macOS_command_line_tools
  export GREP="grep -E" && readonly GREP
elif [[ "$OSTYPE" == "linux-gnu" ]]; then
  platform="linux"
  shell_preferred="$(basename "$SHELL")"
  miniconda_installer="Miniconda3-py${miniconda_python_version}_${miniconda_version}-Linux-x86_64.sh"
  platform_lockfile="${cwd}/conda/conda-linux-64.lock"
  export GREP="grep -P" && readonly GREP
else
  fail "Unsupported OS"
  exit 1
fi

success "$platform detected"


######-------------------------------- SHELL INFO -----------------------------------######


shell_current=$(ps -o comm= $PPID | cut -f 1 -d " ")
shell_current=${shell_current#-}  # remove the leading dash that login shells have

if [[ "$shell_current" != "$shell_preferred" ]]; then
  warn "The current shell is $shell_current but your default is $shell_preferred"
fi

if ! shellrc=$(get_shell_rcfile "$shell_current" "$platform"); then
  fail "The shell \"$shell_current\" is not supported"
  exit 1
fi


######--------------------------- MINICONDA INSTALLATION ----------------------------######


if CONDA=$(get_host_conda_command); then
  export CONDA && readonly CONDA
  success "$CONDA is already installed for $shell_current"
  eval "$(get_shell_hook "$shell_current")"
  miniconda_installed=0
else
  warn "Couldn't find an existing Conda/Mamba installation"
  download_and_install_miniconda "$miniconda_installer"
  export CONDA="conda" && readonly CONDA

  # Initialize conda so that we can use commands in this script
  . <(sed -n "$(get_init_block_regex "$CONDA")" "$shellrc")
  eval "$(get_shell_hook "$shell_current")"
  $CONDA config --set auto_activate_base false

  success "Miniconda installed"
  miniconda_installed=1
  rm "$miniconda_installer"
fi


######----------------------------- CREATE ENVIRONMENT ------------------------------######


if get_env_list | $GREP -q "^${env_name}\t/"; then
  echo
  echo "The Conda environment \"$env_name\" already exists"
  echo "It must be removed and recreated"
  echo
  read -p "Would you like to proceed? [y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^y$ ]]; then
    remove_environment "$env_name"
  elif [[ $REPLY =~ ^n$ ]]; then
    fail "Exiting..."
    exit 1
  else
    fail "Invalid option: $REPLY"
    exit 1
  fi
fi

setup_environment "$env_name" "$platform_lockfile"
$CONDA activate "$env_name"

# Set environment variable for Python import stability
# Equivalent (unsupported by Mamba): `conda env config vars set PYTHONNOUSERSITE=1`
echo '{"env_vars": {"PYTHONNOUSERSITE": "1"}}' > "$CONDA_PREFIX/conda-meta/state"


######---------------------------- tinyRNA INSTALLATION -----------------------------######


status "Installing tinyRNA codebase via pip..."
logfile="pip_install_${ts}.log"

if ! pip install "$cwd" > "$logfile" 2>&1; then
  fail "Failed to install tinyRNA codebase (see ${logfile})"
  exit 1
fi
success "tinyRNA codebase installed"


######---------------------------------- FINALIZE -----------------------------------######


success "Setup complete"
if [[ $miniconda_installed -eq 1 ]]; then
  echo
  echo "First, run this one-time command to finalize the Miniconda installation:"
  echo
  echo "  source $shellrc"
fi
echo
echo "To activate the environment, run:"
echo
echo "  $CONDA activate $env_name"
echo
