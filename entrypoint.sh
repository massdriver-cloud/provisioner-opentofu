#!/bin/bash
set -euo pipefail

entrypoint_dir="/massdriver"

params_path="$entrypoint_dir/params.json"
connections_path="$entrypoint_dir/connections.json"
config_path="$entrypoint_dir/config.json"
envs_path="$entrypoint_dir/envs.json"
secrets_path="$entrypoint_dir/secrets.json"

# Extract OpenTofu config
json_output=$(jq -r '.json // false' "$config_path")

# Extract Checkov config
checkov_enabled=$(jq -r '.checkov.enable // true' "$config_path")
checkov_quiet=$(jq -r '.checkov.quiet // true' "$config_path")
checkov_halt_on_failure=$(jq -r '.checkov.halt_on_failure // false' "$config_path")

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
        echo "Unsupported action: $action"
        exit 1
        ;;
esac

xo provisioner terraform backend http -s "$MASSDRIVER_STEP_PATH" -o backend.tf.json

tofu init -input=false
tofu plan $tf_flags -out tf.plan

# Run validations if the command is not 'destroy'
if [ "$MASSDRIVER_DEPLOYMENT_ACTION" != "decommission" ]; then
    tofu show -json tf.plan > tfplan.json

    # Run Checkov if enabled
    if [ "$checkov_enabled" = "true" ]; then
        echo "evaluating Checkov policies"
        checkov_flags=""

        if [ "$checkov_quiet" = "true" ]; then
            checkov_flags+=" --quiet"
        fi
        if [ "$checkov_halt_on_failure" = "false" ]; then
            checkov_flags+=" --soft-fail"
        fi

        checkov --framework terraform_plan -f tfplan.json $checkov_flags --download-external-modules false --repo-root-for-plan-enrichment . --deep-analysis
        #checkov --framework terraform -d . $checkov_flags
    fi

    # Check for invalid deletions
    if [ -f validations.json ]; then
        echo "evaluating OPA rules"
        opa eval --fail-defined --data /opa/terraform.rego --input tfplan.json --data validations.json "data.terraform.deletion_violations[x]" > /dev/null
    fi
fi

if [ "$MASSDRIVER_DEPLOYMENT_ACTION" = "plan" ]; then
    exit 0
fi

tofu apply $tf_flags tf.plan

# Handle artifacts if deployment action is 'provision' or 'decommission'
case "$MASSDRIVER_DEPLOYMENT_ACTION" in
    provision )
        tofu show -json  | jq '.values.outputs // {}' > outputs.json
        jq -s '{params:.[0],connections:.[1],outputs:.[2]}' "$params_path" "$connections_path" outputs.json > artifact_inputs.json
        for artifact_file in artifact_*.jq; do
            [ -f "$artifact_file" ] || break
            field=$(echo "$artifact_file" | sed 's/^artifact_\(.*\).jq$/\1/')
            echo "Creating artifact for field $field"
            jq -f "$artifact_file" artifact_inputs.json | xo artifact publish -d "$field" -n "Artifact $field for $name_prefix" -f -
        done
        ;;
    decommission )
        for artifact_file in artifact_*.jq; do
            [ -f "$artifact_file" ] || break
            field=$(echo "$artifact_file" | sed 's/^artifact_\(.*\).jq$/\1/')
            echo "Deleting artifact for field $field"
            xo artifact delete -d "$field" -n "Artifact $field for $name_prefix"
        done
        ;;
esac