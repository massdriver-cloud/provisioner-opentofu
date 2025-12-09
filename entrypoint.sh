#!/bin/bash
set -euo pipefail

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color (reset)

entrypoint_dir="/massdriver"

params_path="$entrypoint_dir/params.json"
connections_path="$entrypoint_dir/connections.json"
config_path="$entrypoint_dir/config.json"
envs_path="$entrypoint_dir/envs.json"
secrets_path="$entrypoint_dir/secrets.json"

# Utility function for extracting JSON booleans with default values (since jq "//" doesn't work for properly for booleans)
jq_bool_default() {
  local query="${1:-}"
  local default="${2:-}"
  local data="${3:-}"

  if [ -z "$query" ] || [ -z "$default" ] || [ -z "$data" ]; then
    echo -e "${RED}jq_bool_default: missing argument(s)${NC}"
    exit 1
  fi
  
  jq -r "if $query == null then $default else $query end" "$data"
}

# Utility function for evaluating Checkov policies
evaluate_checkov() {
    if [ "$checkov_enabled" = "true" ]; then
        echo -e "\nEvaluating Checkov policies..."
        checkov_flags=""

        if [ "$checkov_quiet" = "true" ]; then
            checkov_flags+=" --quiet"
        fi
        if [ "$checkov_halt_on_failure" = "false" ]; then
            checkov_flags+=" --soft-fail"
        fi
        
        # Setting log level error to avoid Checkov's unavoidable WARNING about not downloading external modules
        LOG_LEVEL=error checkov --repo-root-for-plan-enrichment . --deep-analysis $checkov_flags --framework terraform_plan -f tfplan.json
        echo -e "${GREEN}Checkov evaluation completed.${NC}"
    fi
}

# Extract provisioner configuration
json_output=$(jq -r '.json // false' "$config_path")
name_prefix=$(jq -r '.md_metadata.name_prefix' "$params_path")

# Extract Checkov configuration
checkov_enabled=$(jq_bool_default '.checkov.enable' true "$config_path")
checkov_quiet=$(jq_bool_default '.checkov.quiet' true "$config_path")
checkov_halt_on_failure=$(jq_bool_default '.checkov.halt_on_failure' false "$config_path")

# Setup envs for Massdriver HTTP state backend 
MASSDRIVER_SHORT_PACKAGE_NAME=$(echo $MASSDRIVER_PACKAGE_NAME | sed 's/-[a-z0-9]\{4\}$//')
export TF_HTTP_USERNAME=${MASSDRIVER_DEPLOYMENT_ID}
export TF_HTTP_PASSWORD=${MASSDRIVER_TOKEN}
export TF_HTTP_ADDRESS="https://api.massdriver.cloud/state/${MASSDRIVER_SHORT_PACKAGE_NAME}/${MASSDRIVER_STEP_PATH}"
export TF_HTTP_LOCK_ADDRESS=${TF_HTTP_ADDRESS}
export TF_HTTP_UNLOCK_ADDRESS=${TF_HTTP_ADDRESS}

# Have to copy the secrets file to the bundle directory for backwards compatibility with the legacy provisioner.
# This has been deprecated and should be removed in the future once users have had a chance to update their bundles.
if [ -f "$secrets_path" ]; then
    cp "$secrets_path" "$entrypoint_dir/bundle/secrets.json"
fi

cd bundle/$MASSDRIVER_STEP_PATH

# Copy the params/connections files to the step directory
cp "$connections_path" _connections.auto.tfvars.json
cp "$params_path" _params.auto.tfvars.json

tf_flags="-input=false"
if [ "$json_output" = "true" ]; then
    tf_flags+=" -json"
fi

case $MASSDRIVER_DEPLOYMENT_ACTION in
    plan )
        command=plan
        ;;
    provision )
        command=apply
        ;;
    decommission )
        command=destroy
        tf_flags+=" -destroy"
        ;;
    *)
        echo -e "${RED}Error: Unsupported deployment action '$MASSDRIVER_DEPLOYMENT_ACTION'. Expected 'plan', 'provision', or 'decommission'.${NC}"
        exit 1
        ;;
esac

xo provisioner terraform backend http -s "$MASSDRIVER_STEP_PATH" -o backend.tf.json

tofu init -input=false
tofu plan $tf_flags -out tf.plan

# Run validations if the command is not 'destroy'
if [ "$MASSDRIVER_DEPLOYMENT_ACTION" != "decommission" ]; then
    tofu show -json tf.plan | jq > tfplan.json

    # Run Checkov if enabled
    evaluate_checkov
fi

if [ "$MASSDRIVER_DEPLOYMENT_ACTION" = "plan" ]; then
    exit 0
fi

echo "Applying Terraform plan..."
tofu apply $tf_flags tf.plan

# Create artifacts if deployment action is 'provision'
if [ "$MASSDRIVER_DEPLOYMENT_ACTION" = "provision" ]; then
    tofu show -json  | jq '.values.outputs // {} | with_entries(.value = .value.value)' > outputs.json
    jq -s '{params:.[0],connections:.[1],envs:.[2],secrets:.[3],outputs:.[4]}' "$params_path" "$connections_path" "$envs_path" "$secrets_path" outputs.json > artifact_inputs.json
    for artifact_file in artifact_*.jq; do
        [ -f "$artifact_file" ] || break
        field=$(echo "$artifact_file" | sed 's/^artifact_\(.*\).jq$/\1/')
        echo "Creating artifact for field $field"
        jq -f "$artifact_file" artifact_inputs.json | xo artifact publish -d "$field" -n "Artifact $field for $name_prefix" -f -
    done
fi