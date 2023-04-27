#!/bin/bash
set -eo pipefail

WORK="./buildpacks"

if [ -z "$WORK" ]; then
	echo "WORK cannot be empty"
	exit 254
fi

mkdir -p "$WORK"
rm -rf "${WORK:?}/"*

# A link for the renamed buildpacks
mkdir -p "$WORK/paketo-buildpacks"
ln -s "${PWD}/${WORK}/paketo-buildpacks" "${PWD}/${WORK}/dashaun"

wget -q https://raw.githubusercontent.com/paketo-buildpacks/tiny-builder/main/builder.toml -O $WORK/builder.toml >/dev/null 2>&1 &&
JAVA_NATIVE_IMAGE_VER=$(cat $WORK/builder.toml | grep "docker://gcr.io/paketo-buildpacks/java-native-image:" | cut -d ':' -f 3 | cut -d '"' -f1)
JAVA_VER=$(cat $WORK/builder.toml | grep "docker://gcr.io/paketo-buildpacks/java:" | cut -d ':' -f 3 | cut -d '"' -f1)
PROCFILE_VER=$(cat $WORK/builder.toml | grep "docker://gcr.io/paketo-buildpacks/procfile:" | cut -d ':' -f 3 | cut -d '"' -f1)
GO_VER=$(cat $WORK/builder.toml | grep "docker://gcr.io/paketo-buildpacks/go:" | cut -d ':' -f 3 | cut -d '"' -f1)

#docker pull dashaun/jammy-build:tiny\
docker pull dmikusa/build-jammy-tiny:0.0.2
#docker pull dashaun/jammy-run:tiny
docker pull dmikusa/run-jammy-tiny:0.0.2
docker pull gcr.io/paketo-buildpacks/procfile:$PROCFILE_VER
docker pull gcr.io/paketo-buildpacks/go:$GO_VER

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
      git clone -q --filter=tree:0 "https://github.com/$BUILDPACK" "$WORK/$BUILDPACK" >/dev/null 2>&1 &&
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
      if [ "$BUILDPACK" != "paketo-buildpacks/yarn" ] && [ "$BUILDPACK" != "paketo-buildpacks/node-engine" ]; then
        echo "Building $BUILDPACK:$VERSION"
        create-package --destination ./out --version "$VERSION"
        echo "Created package for $BUILDPACK:$VERSION"
        pushd ./out >/dev/null
          pack buildpack package "gcr.io/$BUILDPACK:$VERSION"
        popd
      else
        echo "Building $BUILDPACK:$VERSION with alternate script"
        sed -i.bak -e 's/2.1.0/2.1.1/' -- "./scripts/.util/tools.json" && rm -- "./scripts/.util/tools.json.bak"
        # shellcheck disable=SC2016
        sed -i.bak -e 's/jam-${os}/jam-${os}-arm64/' -- "./scripts/.util/tools.sh" && rm -- "./scripts/.util/tools.sh.bak"
        sed -i.bak -e 's/pack-${version}-${os}/pack-${version}-${os}-arm64/' -- "./scripts/.util/tools.sh" && rm -- "./scripts/.util/tools.sh.bak"
        ./scripts/package.sh --version "$VERSION"
        pack buildpack package "gcr.io/$BUILDPACK:$VERSION" --path ./build/buildpack.tgz
      fi
  	popd
  done
}

update_metadata_dependencies() {
    printf "%s" "$1" | jq -c '.metadata.dependencies[]' | while read -r i; do
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
  cp "${TARGET}" "${TARGET}.orig"
  sed -i.bak -e 's/arch=amd64/arch=arm64/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  sed -i.bak -e 's/-amd64.tar.gz/-aarch64.tar.gz/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  update_metadata_dependencies "$(yj -t < ${TARGET})"

  # Syft
  TARGET=$WORK/paketo-buildpacks/syft/buildpack.toml
  cp "${TARGET}" "${TARGET}.orig"
  sed -i.bak -e 's/amd64.tar.gz/arm64.tar.gz/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  update_metadata_dependencies "$(yj -t < ${TARGET})"

  #Watchexec
  TARGET=$WORK/paketo-buildpacks/watchexec/buildpack.toml
  cp "${TARGET}" "${TARGET}.orig"
  sed -i.bak -e 's/arch=amd64/arch=arm64/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  sed -i.bak -e 's/x86_64-unknown/aarch64-unknown/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  update_metadata_dependencies "$(yj -t < ${TARGET})"

  #Java Buildpack
  TARGET=$WORK/$BPID/buildpack.toml
  cp "${TARGET}" "${TARGET}.orig"
  sed -i.bak -e "s/{{.version}}/$BPVER/" -- "${TARGET}" && rm -- "${TARGET}.bak"

  build_local_buildpacks $BPID

  #cd $WORK/$BPID
  pushd "$WORK/$BPID" >/dev/null
    printf "[buildpack]\n  uri = \".\"" > ./package-mod.toml
    cat ./package.toml >> ./package-mod.toml 
    echo "********Building $BPID from $PWD"
    pack buildpack package gcr.io/paketo-buildpacks/java:"${BPVER}" --pull-policy=never --config ./package-mod.toml
  popd
}

java_native_image_work(){
  #UPX
  TARGET=$WORK/paketo-buildpacks/upx/buildpack.toml
  cp "${TARGET}" "${TARGET}.orig"
  sed -i.bak -e 's/amd64/arm64/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  #sed -i.bak -e 's/id = \"paketo-buildpacks\/upx\"/id = \"dashaun\/upx\"/' -- "${TARGET}" && rm -- "${TARGET}.bak"
  update_metadata_dependencies "$(yj -t < ${TARGET})"

  #Java Native Image Buildpack
  TARGET=$WORK/$BPID/buildpack.toml
  cp "${TARGET}" "${TARGET}.orig"
  sed -i.bak -e "s/{{.version}}/$BPVER/" -- "${TARGET}" && rm -- "${TARGET}.bak"

  build_local_buildpacks $BPID
  pushd "$WORK/$BPID" >/dev/null
    printf "[buildpack]\n  uri = \".\"" > ./package-mod.toml
    cat ./package.toml >> ./package-mod.toml
    echo "********Building $BPID"
    pack buildpack package gcr.io/paketo-buildpacks/java-native-image:"${BPVER}" --pull-policy=never --config ./package-mod.toml
  popd
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
cat "${PWD}"/stack/mystack.toml >> "${TARGET}"

pushd $WORK
  pack builder create dashaun/builder-arm:tiny -c ./builder.toml --pull-policy never
popd

docker push dashaun/builder-arm:tiny