#!/bin/bash
set -eo pipefail

WORK="./buildpacks"

if [ -z "$WORK" ]; then
	echo "WORK cannot be empty"
	exit 254
fi

mkdir -p "$WORK"
rm -rf "${WORK:?}/"*

wget -q https://raw.githubusercontent.com/paketo-buildpacks/tiny-builder/main/builder.toml -O $WORK/builder.toml >/dev/null 2>&1 &&
JAVA_NATIVE_IMAGE_VER=$(cat $WORK/builder.toml | grep "docker://gcr.io/paketo-buildpacks/java-native-image:" | cut -d ':' -f 3 | cut -d '"' -f1)
JAVA_VER=$(cat $WORK/builder.toml | grep "docker://gcr.io/paketo-buildpacks/java:" | cut -d ':' -f 3 | cut -d '"' -f1)
PROCFILE_VER=$(cat $WORK/builder.toml | grep "docker://gcr.io/paketo-buildpacks/procfile:" | cut -d ':' -f 3 | cut -d '"' -f1)
GO_VER=$(cat $WORK/builder.toml | grep "docker://gcr.io/paketo-buildpacks/go:" | cut -d ':' -f 3 | cut -d '"' -f1)

docker pull gcr.io/paketo-buildpacks/procfile:$PROCFILE_VER
docker pull gcr.io/paketo-buildpacks/go:$GO_VER

docker build ./stack -t dashaun/stack-build:tiny --target build --build-arg STACK_ID="io.paketo.stacks.tiny"
docker push dashaun/stack-build:tiny

docker build ./stack -t dashaun/stack-run:tiny --target run --build-arg STACK_ID="io.paketo.stacks.tiny"


clone_buildpack (){
  BPID="$1"
  BPVER="$2"
  git clone -q "https://github.com/$BPID" "$WORK/$BPID" >/dev/null 2>&1 &&
  pushd "$WORK/$BPID" >/dev/null
  git -c "advice.detachedHead=false" checkout "v$BPVER"
  popd

  for GROUP in $(yj -t < "$WORK/$BPID/buildpack.toml" | jq -rc '.order[].group[]'); do
    BUILDPACK=$(echo "$GROUP" | jq -r ".id")
    VERSION=$(echo "$GROUP" | jq -r ".version")
    if [ ! -d "$WORK/$BUILDPACK" ]; then
      git clone -q "https://github.com/$BUILDPACK" "$WORK/$BUILDPACK" >/dev/null 2>&1 &&
      pushd "$WORK/$BUILDPACK" >/dev/null
      git -c "advice.detachedHead=false" checkout "v$VERSION"
      popd
    fi
  done
}

build_local_buildpacks() {
  for GROUP in $(yj -t < "$WORK/$BPID/buildpack.toml" | jq -rc '.order[].group[]'); do
  	BUILDPACK=$(echo "$GROUP" | jq -r ".id")
  	VERSION=$(echo "$GROUP" | jq -r ".version")
  	pushd "$WORK/$BUILDPACK" >/dev/null
  		create-package --destination ./out --version "$VERSION"
  		pushd ./out >/dev/null
  			#--preserve-env=PATH pack buildpack package "gcr.io/$BUILDPACK:$VERSION"
  			pack buildpack package "gcr.io/$BUILDPACK:$VERSION"
  		popd
  	popd
  done
}

update_metadata_dependencies() {
  jq -c '.metadata.dependencies[]' "$1" | while read -r i; do
      #printf %s\n $i
      #grab the sha256
      SHA256_REPLACE=$(printf %s "$i" | jq -r .sha256)
      #printf "SHA256_REPLACE %s\n" "$SHA256_REPLACE"
      URI_RESOURCE=$(printf %s "$i" | jq -r .uri)
      #printf "URI_RESOURCE %s\n" "$URI_RESOURCE"
      wget -q "$URI_RESOURCE" --output-document=$WORK/downloaded.tgz >/dev/null 2>&1 &&
      SHA256_NEW=$(shasum -a 256 $WORK/downloaded.tgz | cut -d ' ' -f 1)
      #printf "SHA256_NEW %s\n" "$SHA256_NEW"
      sed -i.bak -e "s/$SHA256_REPLACE/$SHA256_NEW/" -- "${TARGET}" && rm -- "${TARGET}.bak"
    done
}

java_work(){
  # Bellsoft Liberica
  TARGET=$WORK/paketo-buildpacks/bellsoft-liberica/buildpack.toml
  sed -i.bak -e 's/arch=amd64/arch=arm64/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  sed -i.bak -e 's/-amd64.tar.gz/-aarch64.tar.gz/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  yj -t < "${TARGET}" > update_metadata_dependencies

  # Syft
  TARGET=$WORK/paketo-buildpacks/syft/buildpack.toml
  sed -i.bak -e 's/amd64.tar.gz/arm64.tar.gz/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  yj -t < "${TARGET}" > update_metadata_dependencies

  #Watchexec
  TARGET=$WORK/paketo-buildpacks/watchexec/buildpack.toml
  sed -i.bak -e 's/arch=amd64/arch=arm64/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  sed -i.bak -e 's/x86_64-unknown/aarch64-unknown/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  yj -t < "${TARGET}" > update_metadata_dependencies

  #Java Buildpack
  TARGET=$WORK/$BPID/buildpack.toml
  sed -i.bak -e "s/{{.version}}/$BPVER/" -- "${TARGET}" && rm -- "${TARGET}.bak"

  build_local_buildpacks $BPID
  cd $WORK/$BPID
  printf "[buildpack]\n  uri = \".\"" > ./package-mod.toml
  cat ./package.toml >> ./package-mod.toml
  pack buildpack package gcr.io/$BPID:"${BPVER}" --pull-policy=never --config ./package-mod.toml
  cd ../../../
}

java_native_image_work(){
  #Java Native Image Buildpack
  TARGET=$WORK/$BPID/buildpack.toml
  sed -i.bak -e "s/{{.version}}/$BPVER/" -- "${TARGET}" && rm -- "${TARGET}.bak"

  build_local_buildpacks $BPID
  cd $WORK/$BPID
  printf "[buildpack]\n  uri = \".\"" > ./package-mod.toml
  cat ./package.toml >> ./package-mod.toml
  pack buildpack package gcr.io/$BPID:"${BPVER}" --pull-policy=never --config ./package-mod.toml
  cd ../../../
}

clone_buildpack paketo-buildpacks/java "$JAVA_VER"
java_work

clone_buildpack paketo-buildpacks/java-native-image "$JAVA_NATIVE_IMAGE_VER"
java_native_image_work

#Tiny Builder
TARGET=$WORK/builder.toml
sed -i.bak -e '$d' -- "${TARGET}" && rm -- "${TARGET}.bak"
sed -i.bak -e '$d' -- "${TARGET}" && rm -- "${TARGET}.bak"
sed -i.bak -e '$d' -- "${TARGET}" && rm -- "${TARGET}.bak"
sed -i.bak -e '$d' -- "${TARGET}" && rm -- "${TARGET}.bak"
sed -i.bak -e '$d' -- "${TARGET}" && rm -- "${TARGET}.bak"
cat ./stack/mystack.toml >> "${TARGET}"


cd $WORK
pack builder create dashaun/builder-arm:tiny -c ./builder.toml --pull-policy never
cd ..

docker push dashaun/builder-arm:tiny
docker push dashaun/stack-build:tiny
docker push dashaun/stack-run:tiny
docker push dashaun/builder-arm:tiny

docker manifest create dashaun/builder:tiny --amend dashaun/builder-arm:tiny --amend paketobuildpacks/builder:tiny
docker manifest push dashaun/builder:tiny