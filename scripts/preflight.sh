#!/bin/bash
# Pre-flight: provision infrastructure for the clone
# This script is regenerated during onboarding based on the chosen cloud provider.
# Run ./ralph/onboard.sh first — it will rewrite this file with your stack config.
set -euo pipefail

echo "ERROR: scripts/preflight.sh has not been configured yet."
echo ""
echo "Run onboarding first:"
echo "  ./ralph/onboard.sh"
echo ""
echo "Onboarding will rewrite this script for your chosen cloud provider"
echo "(Vercel+Neon, AWS ECS+RDS, GCP, Azure, or custom)."
exit 1
