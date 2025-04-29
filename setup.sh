#!/usr/bin/env bash

# USAGE: if you would like to install under a different conda environment name,
# you can pass the preferred name as the first argument to the script:
#   ./setup.sh preferred_name

env_name=${1:-tinyrna}
miniconda_version="23.3.1-0"
cwd="$(dirname "$0")"

# This is the default Python version that will be used by Miniconda (if Miniconda requires installation).
# Note that this isn't the same as the tinyRNA environment's Python version.
# The tinyRNA environment's Python version is instead specified in the platform lockfile.
miniconda_python_version="310"

function success() {
  check="✓"
  green_on="\033[1;32m"
  green_off="\033[0m"
  printf "${green_on}${check} %s${green_off}\n" "$*"
}

function status() {
  blue_on="\033[1;34m"
  blue_off="\033[0m"
  printf "${blue_on}%s${blue_off}\n" "$*"
}

function fail() {
  nope="⃠"
  red_on="\033[1;31m"
  red_off="\033[0m"
  printf "${red_on}${nope} %s${red_off}\n" "$*"
}

function stop() {
  kill -TERM -$$
}
# Ensures that when user presses Ctrl+C, the script stops
# rather than stopping current task and proceeding to the next
trap 'stop' SIGINT

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

function verify_conda_checksum() {
  local installer_file; local repo_index; local installer_hash; local expected_hash;

  installer_file="$1"
  if ! installer_hash=$(shasum -a 256 "$installer_file" | cut -f 1 -d ' '); then
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
  # Setup tinyRNA environment using our generated lock file
  status "Setting up $env_name environment (this may take a while)..."
  conda create --file $platform_lockfile --name $env_name 2>&1 | tee "env_install.log"
  if ! tr -d \\n < env_install.log | grep -q "Executing transaction: ...working... done"; then
    fail "$env_name environment setup failed"
    echo "Console output has been saved to env_install.log."
    exit 1
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
      exit 1
    fi
  else
    success "Xcode command line tools are already installed"
  fi
}


######--------------------------------- PRECHECKS -----------------------------------######


if [[ $CONDA_DEFAULT_ENV == "$env_name" ]]; then
    fail "You must deactivate the $env_name environment before running this script."
    exit 1
fi


######--------------------------------- HOST INFO -----------------------------------######


if [[ "$OSTYPE" == "darwin"* ]]; then
  platform="macOS"
  arch=$(uname -m)  # Support Apple Silicon
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


  miniconda_installed=0
else
  status "Downloading Miniconda..."
  curl -O -# https://repo.anaconda.com/miniconda/$miniconda_installer
  if [ -f $miniconda_installer ]; then
    success "Miniconda downloaded"
    verify_conda_checksum $miniconda_installer
    status "Running interactive Miniconda installer..."
    # Use bash since the installer appears to no longer work with zsh
    if ! bash $miniconda_installer; then
      fail "Miniconda installation failed"
      exit 1
    fi
  else
    fail "Miniconda failed to download"
    exit 1
  fi

  # Finalize installation
  # Essentially equivalent to calling `source ~/."$shell"rc` but with cross-shell/platform compatibility
  . <(tail -n +$(grep -n "# >>> conda initialize" ~/."$shell"rc | cut -f 1 -d ":") ~/."$shell"rc)
  eval "$(conda shell."$shell" hook)"
  conda config --set auto_activate_base false

  success "Miniconda installed"
  miniconda_installed=1
  rm $miniconda_installer
fi

# Check if the conda environment $env_name exists
if conda env list | grep -q "^${env_name}\s"; then
  echo
  echo "The Conda environment $env_name already exists."
  echo "It must be removed and recreated."
  echo
  read -p "Would you like to proceed? [y/n]: " -n 1 -r

  if [[ $REPLY =~ ^y$ ]]; then
    echo
    echo
    status "Removing $env_name environment..."
    conda env remove -n "$env_name" -y > /dev/null 2>&1
    success "Environment removed"
    setup_environment
  elif [[ $REPLY =~ ^n$ ]]; then
    echo
    echo
    fail "Exiting..."
    exit 1
  else
    echo
    fail "Invalid option: $REPLY"
    exit 1
  fi
else
  # Environment doesn't already exist. Create it.
  setup_environment
fi

# Activate environment and set environment variable config for Linux stability
conda activate $env_name
conda env config vars set PYTHONNOUSERSITE=1 > /dev/null  # FYI: cannot be set by lockfile

# Install the tinyRNA codebase
status "Installing tinyRNA codebase via pip..."
if ! pip install "$cwd" > "pip_install.log" 2>&1; then
  fail "Failed to install tinyRNA codebase"
  echo "Check the pip_install.log file for more information."
  exit 1
fi
success "tinyRNA codebase installed"

success "Setup complete"
if [[ $miniconda_installed -eq 1 ]]; then
  status "First, run this one-time command to finalize the Miniconda installation:"
  echo
  echo "  source ~/${shell}.rc"
  echo
fi
status "To activate the environment, run:"
echo
echo "  conda activate $env_name"
echo
