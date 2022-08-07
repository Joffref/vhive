#!/bin/bash

# MIT License
#
# Copyright (c) 2020 Dmitrii Ustiugov, Plamen Petrov and EASE lab
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT="$( cd $DIR && cd .. && cd .. && pwd)"

STOCK_CONTAINERD=$1
REPO_VOL_SIZE=5Gi

# Install Flannel-Calico network add-on with permitted IP range on cloudlab.
export IFACE=$(netstat -ie | grep -B1 '10.0.1.1' | head -n1 | awk '{print $1}' | cut -d ':' -f 1)
echo $IFACE
cat $ROOT/configs/calico/canal.yaml | envsubst | kubectl apply -f -

# Install and configure MetalLB
kubectl get configmap kube-proxy -n kube-system -o yaml | \
sed -e "s/strictARP: false/strictARP: true/" | \
kubectl apply -f - -n kube-system

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/metallb.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
kubectl apply -f $ROOT/configs/metallb/metallb-configmap.yaml

# export needed for envsubst
export MASTER_NODE_NAME=$(kubectl get nodes -l node-role.kubernetes.io/master | tail -n 1 | cut -d ' ' -f 1)
echo "Master node identified: ${MASTER_NODE_NAME}"
# removing taint from master node to allow control plane scheduling on it
kubectl taint nodes $MASTER_NODE_NAME node-role.kubernetes.io/master-

# istio
cd $ROOT
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.12.5 TARGET_ARCH=x86_64 sh -
export PATH=$PATH:$ROOT/istio-1.12.5/bin
sudo sh -c  "echo 'export PATH=\$PATH:$ROOT/istio-1.12.5/bin' >> /etc/profile"
istioctl install -y -f $ROOT/configs/istio/istio-minimal-operator.yaml

KNATIVE_VERSION="knative-v1.3.0"
# Install KNative in the cluster
if [ "$STOCK_CONTAINERD" == "stock-only" ]; then
    kubectl apply --filename https://github.com/knative/serving/releases/download/$KNATIVE_VERSION/serving-crds.yaml
    #* Knative components for loader.
    cat $ROOT/configs/knative_yamls/loader_serving_core.yaml | envsubst | kubectl apply -f -
else
    kubectl apply --filename $ROOT/configs/knative_yamls/serving-crds.yaml
    cat $ROOT/configs/knative_yamls/serving-core.yaml | envsubst | kubectl apply -f -
fi

# Install local cluster registry
kubectl create namespace registry
REPO_VOL_SIZE=$REPO_VOL_SIZE envsubst < $ROOT/configs/registry/repository-volume.yaml | kubectl create --filename -
kubectl create --filename $ROOT/configs/registry/docker-registry.yaml
kubectl apply --filename $ROOT/configs/registry/repository-update-hosts.yaml 

# magic DNS
kubectl apply --filename $ROOT/configs/knative_yamls/serving-default-domain.yaml

#* Istio controller for loader.
kubectl apply --filename $ROOT/configs/knative_yamls/loader_istio_controller.yaml

# install knative eventing
kubectl apply --filename https://github.com/knative/eventing/releases/download/$KNATIVE_VERSION/eventing-crds.yaml
kubectl apply --filename https://github.com/knative/eventing/releases/download/$KNATIVE_VERSION/eventing-core.yaml

# todo: need to replace this with Kafka
# install a default Channel (messaging) layer
kubectl apply --filename https://github.com/knative/eventing/releases/download/$KNATIVE_VERSION/in-memory-channel.yaml

# install a Broker (eventing) layer:
kubectl apply --filename https://github.com/knative/eventing/releases/download/$KNATIVE_VERSION/mt-channel-broker.yaml

kubectl --namespace istio-system get service istio-ingressgateway
