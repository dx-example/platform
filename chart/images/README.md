# Building images

## Login

docker login quay.io

1. ```docker build -t moonpod/base . -f Containerfile --platform=linux/amd64```
2. docker tag docker.io/moonpod/base quay.io/mmaestri/tools:base
3. docker push quay.io/mmaestri/tools:base
