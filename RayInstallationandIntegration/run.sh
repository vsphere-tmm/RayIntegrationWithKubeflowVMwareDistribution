#!/bin/bash
 
NAMESPACE="ray"
rayclusterwithgpu=true
 
# 0. check install Helm or not
if command -v helm &> /dev/null
then
    echo "Helm already installed"
else
    echo "Helm have not installed"
    curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
    sudo apt-get install apt-transport-https --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt-get update
    sudo apt-get install helm
 
    echo "Helm is installed successfully"
fi
 
# 1. Install Kuberay operator
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
 
# Check if the namespace exists
if kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo "Namespace '$NAMESPACE' already exists."
else
    # Create the namespace if it doesn't exist
    kubectl create namespace "$NAMESPACE"
    echo "Namespace '$NAMESPACE' created."
fi
  
# Install both CRDs and KubeRay operator v0.5.0.
helm install kuberay-operator kuberay/kuberay-operator --version 0.5.0 -n $NAMESPACE
 
# Check the KubeRay operator Pods in the 'ray' namespace
kubectl get pods -n $NAMESPACE
 
# 2. Install RayCluster
if [ "$rayclusterwithgpu" = true ]; then
    echo "Create an autoscaling RayCluster custom resource with GPU."
    cat << EOF | kubectl apply -f -
    apiVersion: ray.io/v1alpha1
    kind: RayCluster
    metadata:
      labels:
        controller-tools.k8s.io: "1.0"
      name: raycluster-autoscaler
      namespace: $NAMESPACE
    spec:
      rayVersion: '2.2.0'
      enableInTreeAutoscaling: true
      autoscalerOptions:
        upscalingMode: Default
        idleTimeoutSeconds: 60
        imagePullPolicy: IfNotPresent
        securityContext: {}
        env: []
        envFrom: []
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "500m"
            memory: "512Mi"
      headGroupSpec:
        serviceType: ClusterIP # optional
        rayStartParams:
          dashboard-host: '0.0.0.0'
          block: 'true'
        template:
          spec:
            containers:
            - name: ray-head
              image: rayproject/ray-ml:2.2.0-py38-gpu
              ports:
              - containerPort: 6379
                name: gcs
              - containerPort: 8265
                name: dashboard
              - containerPort: 10001
                name: client
              lifecycle:
                preStop:
                  exec:
                    command: ["/bin/sh","-c","ray stop"]
              resources:
                limits:
                  cpu: "4"
                  memory: "32G"
                requests:
                  cpu: "4"
                  memory: "16G"
      workerGroupSpecs:
      - replicas: 1
        minReplicas: 1
        maxReplicas: 10
        groupName: small-group
        rayStartParams:
          num-gpus: "1"
        template:
          spec:
            initContainers:
            - name: init
              image: busybox:1.28
              command: ['sh', '-c', "until nslookup $RAY_IP.$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace).svc.cluster.local; do echo waiting for K8s Service $RAY_IP; sleep 2; done"]
            containers:
            - name: ray-worker
              image: rayproject/ray-ml:2.2.0-py38-gpu
              lifecycle:
                preStop:
                  exec:
                    command: ["/bin/sh","-c","ray stop"]
              resources:
                limits:
                  cpu: "8"
                  memory: "32G"
                  nvidia.com/gpu: 1
                requests:
                  cpu: "8"
                  memory: "32G"
                  nvidia.com/gpu: 1
EOF
    SVC_HOST="raycluster-autoscaler-head-svc.ray.svc.cluster.local"
    LABEL_SELECTOR="ray.io/cluster=raycluster-autoscaler"
else
    echo "Install the default Raycluster."
    # Create a RayCluster CR, and the KubeRay operator will reconcile a Ray cluster with 1 head Pod and 1 worker Pod.
    helm install raycluster kuberay/ray-cluster --version 0.5.0 --set image.tag=2.2.0-py38-cpu -n $NAMESPACE
    SVC_HOST="raycluster-kuberay-head-svc.ray.svc.cluster.local"
    LABEL_SELECTOR="ray.io/cluster=raycluster-kuberay"
fi
 
# Check RayCluster
# kubectl get pod -n ray
 
# Function to check if all pods are running
check_pods_status() {
    local pod_status
    pod_status=$(kubectl get pod -l "$LABEL_SELECTOR" -n "$NAMESPACE" -o jsonpath='{.items[*].status.phase}')
     
    if [[ "$pod_status" =~ .*Running.* ]]; then
        return 0  # All pods are running
    else
        return 1  # Some pods are not running
    fi
}
 
# Maximum number of attempts before giving up
MAX_ATTEMPTS=30
 
# Interval between checks (in seconds)
CHECK_INTERVAL=5
 
# Loop to check the pod status
attempts=0
while [ $attempts -lt $MAX_ATTEMPTS ]; do
    if check_pods_status; then
        echo "All pods are running."
        pod_status=1
        break
    else
        echo "Waiting for pods to become running (Attempt $((attempts + 1)) of $MAX_ATTEMPTS)..."
        sleep "$CHECK_INTERVAL"
        ((attempts++))
    fi
done
 
# echo "Some pods did not become running after $MAX_ATTEMPTS attempts."
 
# 3. Integrate with Kubeflow
# Create virtual services
if [ "$pod_status" -eq 1 ]; then
    echo "Integrate with Kubeflow"
    cat << EOF | kubectl apply -f -
    apiVersion: networking.istio.io/v1alpha3
    kind: VirtualService
    metadata:
      name: ray-cluster-virtual-service
      namespace: kubeflow
    spec:
      gateways:
      - kubeflow-gateway
      hosts:
      - '*'
      http:
      - match:
        - uri:
            prefix: /ray-cluster/
        rewrite:
          uri: /
        route:
        - destination:
            host: $SVC_HOST
            port:
              number: 8265
EOF
 
    # Update centraldashboard-config
    kubectl get configmap centraldashboard-config -n kubeflow -o jsonpath='{.data.links}' > current.json
    if [[ $( cat current.json | jq '.menuLinks[] | select(.link == "/ray-cluster/")' ) == "" ]]; then
      new_item='{
        "type": "item",
        "link": "/ray-cluster/",
        "text": "Ray on vSphere",
        "icon": "book"
      }'
      cat current.json | jq '.menuLinks |= map(if .link == "/pipeline/#/artifacts" then ., '"$new_item"' else . end)' > updated.json
      kubectl get configmap centraldashboard-config -n kubeflow -o jsonpath='{.data.settings}' > settings.json
      kubectl create configmap centraldashboard-config --from-file=links=updated.json --from-file=settings=settings.json -n kubeflow --dry-run=client -o yaml | kubectl apply -f -
      rm current.json updated.json settings.json
    fi
else
    echo "Some pods did not become running after $MAX_ATTEMPTS attempts."
fi

