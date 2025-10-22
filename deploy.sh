#!/bin/bash

################################################################################
# Production-Grade Dockerized Application Deployment Script
# Author: DevOps Automation
# Description: Automates setup, deployment, and configuration of Dockerized apps
################################################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures

################################################################################
# CONFIGURATION
# Note: Sensitive values should be set as environment variables
################################################################################
GIT_REPO_URL="https://github.com/Steveraw400/HNG-Docker-App.git"
GIT_PAT="${GIT_PAT:-}"  # Set via: export GIT_PAT="your_token"
GIT_BRANCH="main"
SSH_USER="ubuntu"
SERVER_IP="16.171.172.51"
SSH_HOST="ec2-16-171-172-51.eu-north-1.compute.amazonaws.com"
SSH_KEY_PATH="/home/vagrant/.ssh/oasis.pem"
APP_PORT="5000"
APP_NAME="my-docker-app"

################################################################################
# GLOBAL VARIABLES
################################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/deploy_$$"
CLEANUP_MODE=false

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# LOGGING FUNCTIONS
################################################################################
setup_logging() {
    mkdir -p "${LOG_DIR}"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    log_info "=== Deployment Script Started at $(date) ==="
    log_info "Configuration:"
    log_info "  Repository: ${GIT_REPO_URL}"
    log_info "  Branch: ${GIT_BRANCH}"
    log_info "  Server: ${SSH_USER}@${SERVER_IP}"
    log_info "  SSH Host: ${SSH_HOST}"
    log_info "  App Port: ${APP_PORT}"
    log_info "  App Name: ${APP_NAME}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_success() {
    echo -e "${BLUE}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

################################################################################
# ERROR HANDLING
################################################################################
cleanup_on_error() {
    local exit_code=$?
    log_error "Script failed with exit code: ${exit_code}"
    log_info "Cleaning up temporary files..."
    rm -rf "${TEMP_DIR}"
    log_info "Check log file for details: ${LOG_FILE}"
    exit "${exit_code}"
}

trap cleanup_on_error ERR INT TERM

################################################################################
# VALIDATION FUNCTIONS
################################################################################
validate_configuration() {
    log_info "=== Validating Configuration ==="
    
    # Check if PAT is set
    if [ -z "${GIT_PAT}" ]; then
        log_error "GITHUB_PAT environment variable is not set"
        log_error "Please set it with: export GITHUB_PAT='your_token_here'"
        exit 1
    fi
    
    # Validate SSH key exists
    if [ ! -f "${SSH_KEY_PATH}" ]; then
        log_error "SSH key not found: ${SSH_KEY_PATH}"
        exit 1
    fi
    
    # Check SSH key permissions
    local perms=$(stat -c %a "${SSH_KEY_PATH}" 2>/dev/null || stat -f %A "${SSH_KEY_PATH}" 2>/dev/null)
    if [ "${perms}" != "600" ] && [ "${perms}" != "400" ]; then
        log_warn "SSH key has insecure permissions. Setting to 600..."
        chmod 600 "${SSH_KEY_PATH}"
    fi
    
    log_success "Configuration validated"
}

################################################################################
# REPOSITORY OPERATIONS
################################################################################
clone_or_update_repo() {
    log_info "=== Cloning/Updating Repository ==="
    
    # Extract repo name from URL
    REPO_NAME=$(basename "${GIT_REPO_URL}" .git)
    REPO_DIR="${TEMP_DIR}/${REPO_NAME}"
    
    mkdir -p "${TEMP_DIR}"
    
    # Construct authenticated URL
    CLEAN_URL=$(echo "${GIT_REPO_URL}" | sed 's/\/$//' | xargs)
    AUTH_URL=$(echo "${CLEAN_URL}" | sed "s|https://|https://${GIT_PAT}@|")
    
    if [ -d "${REPO_DIR}/.git" ]; then
        log_info "Repository exists, pulling latest changes..."
        cd "${REPO_DIR}"
        git fetch origin
        git checkout "${GIT_BRANCH}"
        git pull origin "${GIT_BRANCH}"
    else
        log_info "Cloning repository..."
        git clone -b "${GIT_BRANCH}" "${AUTH_URL}" "${REPO_DIR}"
        cd "${REPO_DIR}"
    fi
    
    log_success "Repository ready at: ${REPO_DIR}"
}

verify_docker_files() {
    log_info "=== Verifying Docker Configuration ==="
    
    cd "${REPO_DIR}"
    
    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        DOCKER_COMPOSE_FILE=$(ls docker-compose.y*ml 2>/dev/null | head -n 1)
        log_success "Found Docker Compose file: ${DOCKER_COMPOSE_FILE}"
        USE_COMPOSE=true
    elif [ -f "Dockerfile" ]; then
        log_success "Found Dockerfile"
        USE_COMPOSE=false
    else
        log_error "No Dockerfile or docker-compose.yml found in repository"
        exit 1
    fi
}

################################################################################
# SSH CONNECTIVITY
################################################################################
test_ssh_connection() {
    log_info "=== Testing SSH Connection ==="
    
    if ssh -i "${SSH_KEY_PATH}" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           "${SSH_USER}@${SSH_HOST}" "echo 'SSH connection successful'" &>/dev/null; then
        log_success "SSH connection to ${SSH_HOST} successful"
    else
        log_error "Cannot connect to ${SSH_HOST} via SSH"
        exit 1
    fi
}

################################################################################
# REMOTE ENVIRONMENT SETUP
################################################################################
setup_remote_environment() {
    log_info "=== Setting Up Remote Environment ==="
    
    ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" << 'ENDSSH'
        set -e
        
        echo "[INFO] Updating system packages..."
        sudo apt-get update -qq
        
        echo "[INFO] Installing prerequisites..."
        sudo apt-get install -y -qq apt-transport-https ca-certificates curl software-properties-common
        
        # Install Docker if not present
        if ! command -v docker &> /dev/null; then
            echo "[INFO] Installing Docker..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            rm get-docker.sh
            sudo systemctl enable docker
            sudo systemctl start docker
        else
            echo "[INFO] Docker already installed"
        fi
        
        # Install Docker Compose if not present
        if ! command -v docker-compose &> /dev/null; then
            echo "[INFO] Installing Docker Compose..."
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
                 -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        else
            echo "[INFO] Docker Compose already installed"
        fi
        
        # Install Nginx if not present
        if ! command -v nginx &> /dev/null; then
            echo "[INFO] Installing Nginx..."
            sudo apt-get install -y -qq nginx
            sudo systemctl enable nginx
            sudo systemctl start nginx
        else
            echo "[INFO] Nginx already installed"
        fi
        
        # Add user to docker group
        sudo usermod -aG docker $USER || true
        
        echo "[SUCCESS] Environment setup complete"
        echo "[INFO] Docker version: $(docker --version)"
        echo "[INFO] Docker Compose version: $(docker-compose --version)"
        echo "[INFO] Nginx version: $(nginx -v 2>&1)"
ENDSSH
    
    log_success "Remote environment configured"
}

################################################################################
# FILE TRANSFER
################################################################################
transfer_files() {
    log_info "=== Transferring Files to Remote Server ==="
    
    REMOTE_DIR="/home/${SSH_USER}/apps/${APP_NAME}"
    
    # Create remote directory
    ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" \
        "mkdir -p ${REMOTE_DIR}"
    
    # Transfer files using rsync
    log_info "Syncing files to ${SSH_HOST}:${REMOTE_DIR}..."
    rsync -avz --progress -e "ssh -i ${SSH_KEY_PATH}" \
          --exclude='.git' \
          --exclude='node_modules' \
          --exclude='__pycache__' \
          --exclude='*.log' \
          "${REPO_DIR}/" "${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/"
    
    log_success "Files transferred successfully"
}

################################################################################
# DOCKER DEPLOYMENT
################################################################################
deploy_application() {
    log_info "=== Deploying Dockerized Application ==="
    
    ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" << ENDSSH
        set -e
        cd /home/${SSH_USER}/apps/${APP_NAME}
        
        echo "[INFO] Stopping existing containers..."
        docker stop ${APP_NAME} 2>/dev/null || true
        docker rm ${APP_NAME} 2>/dev/null || true
        
        if [ "${USE_COMPOSE}" = "true" ]; then
            echo "[INFO] Deploying with Docker Compose..."
            docker-compose down || true
            docker-compose build
            docker-compose up -d
        else
            echo "[INFO] Building Docker image..."
            docker build -t ${APP_NAME}:latest .
            
            echo "[INFO] Running Docker container..."
            docker run -d \
                --name ${APP_NAME} \
                --restart unless-stopped \
                -p 127.0.0.1:${APP_PORT}:${APP_PORT} \
                ${APP_NAME}:latest
        fi
        
        echo "[SUCCESS] Application deployed"
ENDSSH
    
    log_success "Application deployment complete"
}

validate_deployment() {
    log_info "=== Validating Deployment ==="
    
    sleep 5  # Wait for container to fully start
    
    ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" << ENDSSH
        set -e
        
        echo "[INFO] Checking Docker service..."
        if ! sudo systemctl is-active --quiet docker; then
            echo "[ERROR] Docker service is not running"
            exit 1
        fi
        
        echo "[INFO] Checking container status..."
        if [ "${USE_COMPOSE}" = "true" ]; then
            docker-compose ps
        else
            docker ps --filter "name=${APP_NAME}"
        fi
        
        echo "[INFO] Checking container health..."
        CONTAINER_ID=\$(docker ps -q --filter "name=${APP_NAME}")
        if [ -z "\$CONTAINER_ID" ]; then
            echo "[ERROR] Container is not running"
            exit 1
        fi
        
        echo "[INFO] Container logs (last 20 lines):"
        docker logs --tail 20 ${APP_NAME}
        
        echo "[SUCCESS] Container is running successfully"
ENDSSH
    
    log_success "Deployment validated"
}

################################################################################
# NGINX CONFIGURATION
################################################################################
configure_nginx() {
    log_info "=== Configuring Nginx Reverse Proxy ==="
    
    NGINX_CONFIG="/etc/nginx/sites-available/${APP_NAME}"
    
    ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" << ENDSSH
        set -e
        
        echo "[INFO] Fixing Nginx hash bucket size..."
        # Add server_names_hash_bucket_size to nginx.conf if not present
        if ! sudo grep -q "server_names_hash_bucket_size" /etc/nginx/nginx.conf; then
            sudo sed -i '/http {/a \    server_names_hash_bucket_size 128;' /etc/nginx/nginx.conf
            echo "[INFO] Added server_names_hash_bucket_size to nginx.conf"
        else
            echo "[INFO] server_names_hash_bucket_size already configured"
        fi
        
        echo "[INFO] Creating Nginx configuration..."
        sudo tee ${NGINX_CONFIG} > /dev/null << 'EOF'
server {
    listen 80 default_server;
    server_name ${SERVER_IP} ${SSH_HOST};
    
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        
        echo "[INFO] Removing default Nginx site to prevent conflicts..."
        sudo rm -f /etc/nginx/sites-enabled/default
        
        echo "[INFO] Enabling site..."
        sudo ln -sf ${NGINX_CONFIG} /etc/nginx/sites-enabled/${APP_NAME}
        
        echo "[INFO] Testing Nginx configuration..."
        sudo nginx -t
        
        echo "[INFO] Reloading Nginx..."
        sudo systemctl reload nginx
        
        echo "[SUCCESS] Nginx configured and reloaded"
ENDSSH
    
    log_success "Nginx reverse proxy configured"
}

test_endpoint() {
    log_info "=== Testing Application Endpoint ==="
    
    sleep 3  # Wait for Nginx to fully reload
    
    log_info "Testing local endpoint on server..."
    ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" \
        "curl -s -o /dev/null -w 'HTTP Status: %{http_code}\n' http://localhost:${APP_PORT} || echo 'Local test failed'"
    
    log_info "Testing via Nginx (IP)..."
    if curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}" | grep -q "200\|301\|302"; then
        log_success "Application is accessible at http://${SERVER_IP}"
    else
        log_warn "Application may not be responding correctly via IP. Check logs."
    fi
    
    log_info "Testing via Nginx (hostname)..."
    if curl -s -o /dev/null -w "%{http_code}" "http://${SSH_HOST}" | grep -q "200\|301\|302"; then
        log_success "Application is accessible at http://${SSH_HOST}"
    else
        log_warn "Application may not be responding correctly via hostname. Check logs."
    fi
}

################################################################################
# CLEANUP OPERATIONS
################################################################################
cleanup_deployment() {
    log_info "=== Cleaning Up Deployment ==="
    
    ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SSH_HOST}" << ENDSSH
        set -e
        
        echo "[INFO] Stopping and removing containers..."
        docker stop ${APP_NAME} 2>/dev/null || true
        docker rm ${APP_NAME} 2>/dev/null || true
        
        echo "[INFO] Removing Nginx configuration..."
        sudo rm -f /etc/nginx/sites-enabled/${APP_NAME}
        sudo rm -f /etc/nginx/sites-available/${APP_NAME}
        sudo systemctl reload nginx
        
        echo "[INFO] Removing application files..."
        rm -rf /home/${SSH_USER}/apps/${APP_NAME}
        
        echo "[SUCCESS] Cleanup complete"
ENDSSH
    
    log_success "Deployment cleaned up"
}

final_cleanup() {
    log_info "=== Final Cleanup ==="
    rm -rf "${TEMP_DIR}"
    log_success "Temporary files removed"
}

################################################################################
# MAIN EXECUTION
################################################################################
main() {
    setup_logging
    
    # Check for cleanup flag
    if [ "${1:-}" = "--cleanup" ]; then
        CLEANUP_MODE=true
        validate_configuration
        test_ssh_connection
        cleanup_deployment
        exit 0
    fi
    
    log_info "Starting deployment process..."
    
    validate_configuration
    clone_or_update_repo
    verify_docker_files
    test_ssh_connection
    setup_remote_environment
    transfer_files
    deploy_application
    validate_deployment
    configure_nginx
    test_endpoint
    final_cleanup
    
    log_success "==================================================================="
    log_success "Deployment completed successfully!"
    log_success "Application URLs:"
    log_success "  - http://${SERVER_IP}"
    log_success "  - http://${SSH_HOST}"
    log_success "Container name: ${APP_NAME}"
    log_success "Log file: ${LOG_FILE}"
    log_success "==================================================================="
    log_info "To cleanup this deployment, run: $0 --cleanup"
}

# Run main function
main "$@"
