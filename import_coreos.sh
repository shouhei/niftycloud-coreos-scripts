#!/bin/bash -x

# You need to set following environment variables.
# NIFTY_ACCESS_KEY_ID
# NIFTY_SECRET_KEY
# NIFTY_CLOUD_ACCESS_KEY
# NIFTY_CLOUD_SECRET_KEY
# NIFTY_CLOUD_STORAGE_BACKET_NAME
# NIFTY_ZONE
# NIFTY_FW_GROUP
# COREOS_CHANNEL
# SUFFIX

cd $(dirname $0)
WORKDIR=$(pwd)

if [ "$COREOS_CHANNEL" == "" ] ; then
  echo "You need to set COREOS_CHANNEL"
  exit 0
fi

if [ "$COREOS_VERSION" == "" ] ; then
  COREOS_VERSION=current
fi

# Make temp dir
DIR=$(mktemp -d)
cp -p init.sh $DIR/
pushd $DIR

# Install NIFTY Cloud CLI
wget -q http://cloud.nifty.com/api/sdk/NIFTY_Cloud_api-tools.zip
unzip NIFTY_Cloud_api-tools.zip
rm -f NIFTY_Cloud_api-tools.zip
rm -rf NIFTY_Cloud_api-tools/bin/*.cmd
chmod +x NIFTY_Cloud_api-tools/bin/*
export NIFTY_CLOUD_HOME=$(pwd)/NIFTY_Cloud_api-tools/
export PATH=${PATH}:${NIFTY_CLOUD_HOME}/bin

# Check if NIFTY Cloud is in maintenance.
NIFTYCLOUD_STATUS=$(nifty-describe-service-status)
if [ "$(echo "${NIFTYCLOUD_STATUS}"|grep "Service.Maintenance")" ]; then
    echo "MESSAGE = NIFTY Cloud is in maintenance."
    exit 1
fi

# Download and check CoreOS Image for NIFTY Cloud
BASE_URL=http://${COREOS_CHANNEL,,}.release.core-os.net/amd64-usr/$COREOS_VERSION
VERSION_TXT=version.txt
VERSION_TXT_SIG=version.txt.sig
OVF=coreos_production_niftycloud.ovf
OVF_SIG=coreos_production_niftycloud.ovf.sig
VMDK_BZ2=coreos_production_niftycloud_image.vmdk.bz2
VMDK_BZ2_SIG=coreos_production_niftycloud_image.vmdk.bz2.sig

# Import CoreOS Image Signing Key
curl https://coreos.com/security/image-signing-key/CoreOS_Image_Signing_Key.pem | gpg --import -

# Download version.txt
wget -q ${BASE_URL}/${VERSION_TXT}
wget -q ${BASE_URL}/${VERSION_TXT_SIG}
gpg --verify ${VERSION_TXT_SIG}

VERSION=$(grep 'COREOS_VERSION=' ${VERSION_TXT} | awk -F'=' '{print $2}')
IMAGE_NAME="CoreOS ${COREOS_CHANNEL} ${VERSION}${SUFFIX}"

echo "CoreOS Version: $VERSION"

# Check NIFTY Cloud CoreOS Version
nifty-describe-images --delimiter ',' --image-name "${IMAGE_NAME}" | grep "${IMAGE_NAME}"
if [ $? -eq 0 ] ; then
    echo "MESSAGE = ${IMAGE_NAME} is already released."
    exit 1
fi

# Download OVF and VMDK
wget -q ${BASE_URL}/${OVF}
wget -q ${BASE_URL}/${OVF_SIG}
gpg --verify ${OVF_SIG}
wget -q ${BASE_URL}/${VMDK_BZ2}
wget -q ${BASE_URL}/${VMDK_BZ2_SIG}
gpg --verify ${VMDK_BZ2_SIG}

bunzip2 ${VMDK_BZ2}
VMDK="coreos_production_niftycloud_image.vmdk"

echo "Importing the ovf..."
INSTANCE_ID=$(nifty-import-instance ${VMDK} -t mini -V ${OVF} -g ${NIFTY_FW_GROUP} -z ${NIFTY_ZONE} -q POST | grep "IMPORTINSTANCE" | awk '{print $4}')
echo "done."

# Wait until the instance status is running
get_instance_status() {
    INSTANCE_ID=$1
    STATUS=$(nifty-describe-instances ${INSTANCE_ID} --delimiter ',' | grep 'INSTANCE' | awk -F',' '{print $6}' | tr -d '\n' | tr -d '\r')
    echo ${STATUS}
}

echo "Check status of the instance.."
STATUS=$(get_instance_status ${INSTANCE_ID})
echo ${STATUS}
while [ "${STATUS}" != "running" ]; do
    sleep 10
    STATUS=$(get_instance_status ${INSTANCE_ID})
    echo ${STATUS}
    if [ "${STATUS}" == "import_error" ]; then
        exit 1
    fi
done

# Reboot and execute startup script to remove machine-id
echo "Reboot the instance.."
nifty-reboot-instances ${INSTANCE_ID} -q POST --user-data-file-plain init.sh
sleep 10
STATUS=$(get_instance_status ${INSTANCE_ID})
echo ${STATUS}
while [ "${STATUS}" != "running" ]; do
    sleep 10
    STATUS=$(get_instance_status ${INSTANCE_ID})
    echo ${STATUS}
done

echo "Stop the instance.."
nifty-stop-instances ${INSTANCE_ID}
STATUS=$(get_instance_status ${INSTANCE_ID})
echo ${STATUS}
while [ "${STATUS}" != "stopped" ]; do
    sleep 10
    STATUS=$(get_instance_status ${INSTANCE_ID})
    echo ${STATUS}
done
echo "done."

# Create an image and wait until the image status is available
get_image_status() {
    IMAGE_ID=$1
    STATUS=$(nifty-describe-images ${IMAGE_ID} --delimiter ',' | awk -F',' '{print $6}' | tr -d '\n' | tr -d '\r')
    echo ${STATUS}
}
echo "Create image..."
IMAGE_ID=$(nifty-create-image ${INSTANCE_ID} --request-method "POST" --name "${IMAGE_NAME}" --left-instance false | awk '{print $2}')
STATUS=$(get_image_status ${IMAGE_ID})
while [ "${STATUS}" != "available" ]; do
    sleep 10
    STATUS=$(get_image_status ${IMAGE_ID})
done
echo "done."

# Modify description
DESCRIPTION="ニフティクラウドユーザーブログライター作成パブリックイメージ"
DETAIL="CoreOSのパブリックイメージです。
利用方法につきましては、URL先をご確認ください。
※ユーザーブログライター有志によるイメージ提供となる為、スタンダードイメージ同様OS内容については未サポートとなります。
※初期設定は予告なく変更される場合がありますので、ご了承ください。"
CONTACT_URL="https://coreos.com/docs/running-coreos/cloud-providers/niftycloud/JA_JP/"
wget -q https://github.com/higebu/nifty-modify-image-attribute/releases/download/v1.0/nifty-modify-image-attribute
chmod +x nifty-modify-image-attribute
./nifty-modify-image-attribute -description "${DESCRIPTION}" ${IMAGE_ID}
./nifty-modify-image-attribute -detail-description "${DETAIL}" ${IMAGE_ID}
./nifty-modify-image-attribute -contact-url "${CONTACT_URL}" ${IMAGE_ID}

# Install NIFTY Cloud Storage CLI
echo "Install NIFTY Cloud Storage CLI..."
wget -q http://cloud.nifty.com/api/storage/NiftyCloudStorage-SDK-CLI.zip
unzip NiftyCloudStorage-SDK-CLI.zip
rm -f NiftyCloudStorage-SDK-CLI.zip
chmod +x NiftyCloudStorage-SDK-CLI/ncs_cli.sh
cp ${WORKDIR}/credentials.properties NiftyCloudStorage-SDK-CLI/credentials.properties

# Get and upload CoreOS icon
echo "Get and upload CoreOS icon"
pushd NiftyCloudStorage-SDK-CLI
./ncs_cli.sh get ncss://${NIFTY_CLOUD_STORAGE_BACKET_NAME}/master/coreos.png coreos.png
./ncs_cli.sh --acl-public-read put coreos.png ncss://${NIFTY_CLOUD_STORAGE_BACKET_NAME}/icon/${IMAGE_ID}
popd

# Publish the image
wget -q https://github.com/higebu/nifty-associate-image/releases/download/v1.1/nifty-associate-image
chmod +x nifty-associate-image
./nifty-associate-image -public -redistribute ${IMAGE_ID}

popd
rm -rf $DIR
echo "MESSAGE = ${IMAGE_NAME} is available on NIFTY Cloud!"
