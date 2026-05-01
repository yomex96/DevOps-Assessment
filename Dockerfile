name: E-Permit CI/CD Pipeline

on:
  push:
    branches:
      - main

env:
  IMAGE_NAME: epermit-api
  IMAGE_TAG: ${{ github.sha }}

jobs:
  build-scan-push:
    runs-on: ubuntu-latest

    steps:
      # ----------------------------------------------------
      # Checkout code
      # ----------------------------------------------------
      - name: Checkout repository
        uses: actions/checkout@v4

      # ----------------------------------------------------
      # Build Docker image
      # ----------------------------------------------------
      - name: Build Docker image
        run: docker build -t $IMAGE_NAME:$IMAGE_TAG .

      # ----------------------------------------------------
      # Install Trivy (stable + reliable)
      # ----------------------------------------------------
      - name: Install Trivy
        run: |
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
          trivy --version

      # ----------------------------------------------------
      # Security scan + FAIL ON CRITICAL + generate report
      # ----------------------------------------------------
      - name: Run Trivy scan
        run: |
          trivy image \
            --severity CRITICAL \
            --ignore-unfixed \
            --exit-code 1 \
            --format sarif \
            --output trivy-results.sarif \
            --no-progress \
            $IMAGE_NAME:$IMAGE_TAG

      # ----------------------------------------------------
      # Upload report
      # ----------------------------------------------------
      - name: Upload Trivy report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: trivy-report
          path: trivy-results.sarif

      # ----------------------------------------------------
      # Simulated ECR login
      # ----------------------------------------------------
      - name: Simulate ECR Login
        run: echo "Simulated ECR login using GitHub Secrets"

      # ----------------------------------------------------
      # Simulated push
      # ----------------------------------------------------
      - name: Simulate Docker Push
        run: echo "Image pushed to ECR (simulation)"
