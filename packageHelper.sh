#!/bin/bash
# shellcheck disable=SC2086
# shellcheck disable=SC2001
# shellcheck disable=SC2005
# shellcheck disable=SC2016

#引入配置文件
PROPERTIES="package.properties"
#maven依赖三要素
packageNameV=""
projectNameV=""
buildVersionV=""

#maven仓库地址
mavenRepositoryV=""
mavenSnapshotsV=""

#是否为release版本
isRelease=$1

#当前使用的仓库，根据isRelease的不同而不同
usedMavenRepo=""

#读取配置文件信息并做容错处理
if [ -f "$PROPERTIES" ]
then
  . $PROPERTIES
  packageNameV=$packageName
  projectNameV=$projectName
  buildVersionV=$buildVersion

	if [ -z "$packageNameV" ]; then
      echo ERROR:"package.properties文件中没有配置packageName!"
      exit 1
  fi

  if [ -z "$projectNameV" ]; then
      echo ERROR:"package.properties文件中没有配置projectName!"
      exit 1
  fi

  if [ -z "$buildVersionV" ]; then
      echo ERROR:"package.properties文件中没有配置buildVersion!"
      exit 1
  fi

  mavenRepositoryV=$mavenRepository
  mavenSnapshotsV=$mavenSnapshots

  if [[ -z "$mavenRepositoryV" ]] && [[ -z "$mavenSnapshotsV" ]]
  then
    echo ERROR:"请检查是否在package.properties中正确配置了maven仓库信息!"
      exit 1
  fi
else
  echo ERROR:"请先根据要求配置package.properties文件然后执行该脚本!"
  exit 1
fi

#根据是否为release版来确定使用的仓库地址
if [ $isRelease = "true" ]
then
  usedMavenRepo=$mavenRepositoryV
  echo "当前打包Release版本，版本号:$buildVersion,running..."
else
  usedMavenRepo=$mavenSnapshotsV
  echo "当前打包Debug版本，版本号固定为1.0-SNAPSHOT，running..."
fi

#如果不是release版本，则版本号强行指定为1.0-SNAPSHOT
showBuildVersion=1.0-SNAPSHOT

#打包前清理
echo "flutter clear..."
flutter clean

#打包前获取依赖
echo "flutter pub get..."
flutter pub get

echo "flutter pub get..."

#根据isRelease执行不同的打包逻辑
if [ $isRelease = "true" ]
then
  showBuildVersion=$buildVersionV
  #打包release版本，避免生成多余的包导致资源浪费
  flutter build aar --target-platform android-arm --no-profile --no-debug --build-number "$showBuildVersion"
else
	#打包debug版本，避免生成多余的包导致资源浪费
  flutter build aar --target-platform android-arm --no-profile --no-release --build-number "$showBuildVersion"
fi

echo "aar打包完成，开始上传maven..."

#方法 修改所有pom文件的名称
function renameAllPomArtifactId() {
  find build/host/outputs/repo -name "*.pom" | while read -r file
  do
    sed -i -e "s/>$1</>$2</g" $file
  done
}


#第一次遍历repo文件夹下所有后缀名为.aar的文件
find build/host/outputs/repo -name "*.aar" | while read -r file
do
	#当前aar文件所在的目录
  currDirName=$(dirname $file)
  aarName=$file
  #当前aar文件对应的pom文件（aar和pom一一对应）
  pomName="$currDirName/$(basename $file .aar).pom"

	#从pom文件中读取出groupId信息
  groupId=$(awk '/<groupId>[^<]+<\/groupId>/{gsub(/<groupId>|<\/groupId>/,"",$1);print $1;exit;}' $pomName)
  #从pom文件中读取出artifactId信息，但是此时的artifactId并不是我们在properties中配置的，而是编译器自动生成的
  artifactId=$(awk '/<artifactId>[^<]+<\/artifactId>/{gsub(/<artifactId>|<\/artifactId>/,"",$1);print $1;exit;}' $pomName)

	#修改artifactId为在properties中配置的
  renameAllPomArtifactId $artifactId $projectName
done

#第二次遍历repo文件夹下所有后缀名为.aar的文件，为什么要二次遍历？
#为了防止pom中的artifactId还没有全部修改完便被上传到maven引起的问题
find build/host/outputs/repo -name "*.aar" | while read -r file
do
  #当前aar文件所在的目录
  currDirName=$(dirname $file)
  aarName=$file
  #当前aar文件对应的pom文件（aar和pom一一对应）
  pomName="$currDirName/$(basename $file .aar).pom"

  #从pom文件中读取出groupId信息
  groupId=$(awk '/<groupId>[^<]+<\/groupId>/{gsub(/<groupId>|<\/groupId>/,"",$1);print $1;exit;}' $pomName)
  #从pom文件中读取出artifactId信息，此时已经修改为properties中配置的
  artifactId=$(awk '/<artifactId>[^<]+<\/artifactId>/{gsub(/<artifactId>|<\/artifactId>/,"",$1);print $1;exit;}' $pomName)

  echo "正在上传 = $aarName ..."

	#执行上传maven仓库命令
  mvn deploy:deploy-file \
  -DgroupId=$groupId \
  -DartifactId=$projectName \
  -Dpackaging=aar \
  -Dversion=$showBuildVersion \
  -Dfile=$aarName \
  -DpomFile=$pomName \
  -Durl=$usedMavenRepo

done

#所有操作完成后给一个友善的提示
function finishEcho() {
    echo "
上传完毕！请通过如下方式引入Flutter模块到宿主项目中：
      1. 打开宿主项目根目录build.gradle文件并添加如下引用:

      String storageUrl = System.env.FLUTTER_STORAGE_BASE_URL ?: \"https://storage.googleapis.com\"
      repositories {
        repositories {
            //TODO 删除maven仓库url中配置的账号密码信息
            maven { url \"$1\" }
        }
        maven {
            url \"\$storageUrl/download.flutter.io\"
        }
      }

      2. 在使用到Flutter的模中添加如下依赖:

      dependencies {
        debugImplementation '$2:$3:$4'
        //or
        releaseImplementation '$2:$3:$4'
      }

      3. 同步项目，完成Flutter模块的依赖。
      "
}

finishEcho $usedMavenRepo $packageNameV $projectName $showBuildVersion

