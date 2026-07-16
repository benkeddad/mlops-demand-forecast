#!/bin/bash
# Installs a lightweight Linux binary of Terraform into WSL if it isn't already present.
# Kept as its own real .sh file (instead of an inline string inside deploy_k3s.bat)
# because cmd.exe's batch parser corrupts long bash one-liners containing "!"
# when delayed expansion is enabled - it silently deletes everything between
# the "!" and the next line, which is exactly what was breaking this step.
set -e

if ! command -v terraform &> /dev/null; then
    echo "Installing Terraform in Linux..."

    if ! command -v unzip &> /dev/null; then
        echo "unzip not found - installing it first..."
        if command -v apt-get &> /dev/null; then
            # FIX: Forcefully remove the corrupted Hashicorp list file before updating
            rm -f /etc/apt/sources.list.d/hashicorp.list
            
            apt-get update -qq
            apt-get install -y -qq unzip
        else
            echo "ERROR: unzip is missing and apt-get is not available to install it."
            echo "Install unzip manually in your WSL distro, then re-run this script."
            exit 1
        fi
    fi

    cd /tmp
    TF_VERSION="1.9.0"
    wget -q "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
    unzip -q -o "terraform_${TF_VERSION}_linux_amd64.zip"
    mv terraform /usr/local/bin/
    rm "terraform_${TF_VERSION}_linux_amd64.zip"
else
    echo "Terraform already installed."
fi

terraform -version