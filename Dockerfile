FROM maven:3.8.4-openjdk-8-slim as builder

# Build options
ARG hive_version=2.3.7
ARG spark_version=3.1.2
ARG hadoop_version=3.3.0
ARG aws_java_sdk_version=1.11.797
ARG hudi_version=0.10.0

ENV SPARK_VERSION=${spark_version}
ENV HIVE_VERSION=${hive_version}
ENV HADOOP_VERSION=${hadoop_version}

RUN apt update -yqq; \
  apt install -y \
  git \
  wget \
  python3 \
  python3-pip

COPY maven-settings.xml ${MAVEN_HOME}/conf/settings.xml

WORKDIR /opt

#BUILD HIVE
ADD https://github.com/apache/hive/archive/rel/release-${hive_version}.tar.gz hive.tar.gz

RUN mkdir hive && tar xzf hive.tar.gz --strip-components=1 -C hive

WORKDIR /opt/hive

COPY hive.patch hive.patch

#### Build patched hive
RUN patch -p0 <hive.patch &&\
  mvn  clean install -DskipTests

## Glue support
WORKDIR /opt

RUN git clone https://github.com/bbenzikry/aws-glue-data-catalog-client-for-apache-hive-metastore.git catalog
## Glue support

### Build glue hive client jars
WORKDIR /opt/catalog

RUN mvn clean package \
  -DskipTests \
  -Dhive2.version=${hive_version} \
  -Dhadoop.version=${hadoop_version} \
  -Daws.sdk.version=${aws_java_sdk_version} \
  -Dspark-hive.version=${hive_version} \
  -pl -aws-glue-datacatalog-hive2-client
### Build glue hive client jars

#BUILD SPARK
WORKDIR /opt

RUN git clone https://github.com/apache/spark.git spark

WORKDIR /opt/spark

RUN git checkout "tags/v${SPARK_VERSION}" -b "v${SPARK_VERSION}"

RUN ./dev/make-distribution.sh \
  --name spark \
  --pip \
  -DskipTests \
  -Pkubernetes \
  -Phadoop-cloud \
  -P"hadoop-${hadoop_version%.*}" \
  -Dhadoop.version="${hadoop_version}" \
  -Dhive.version="${hive_version}" \
  -Phive \
  -Phive-thriftserver

COPY conf/* ./dist/conf/

RUN find /opt/catalog -name "*.jar" | grep -Ev "test|original" | xargs -I{} cp {} ./dist/jars

RUN rm ./dist/jars/aws-java-sdk-bundle-*.jar
RUN wget --quiet https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${aws_java_sdk_version}/aws-java-sdk-bundle-${aws_java_sdk_version}.jar -P ./dist/jars/
RUN chmod 0644 ./dist/jars/aws-java-sdk-bundle*.jar

RUN rm -f ./dist/jars/guava-*.jar
RUN wget --quiet https://repo1.maven.org/maven2/com/google/guava/guava/23.0/guava-23.0.jar -P ./dist/jars/
RUN chmod 0644 ./dist/jars/guava-23.0.jar
#BUILD SPARK

# Build Hudi
RUN git clone https://github.com/apache/hudi.git /opt/hudi

WORKDIR /opt/hudi

COPY hudi.patch hudi.patch

RUN git checkout release-${hudi_version}; \
  git apply hudi.patch

RUN mvn clean package \
  -DskipTests \
  -Dspark3 \
  -Daws.sdk.version=${aws_java_sdk_version} \
  -am -pl packaging/hudi-spark-bundle,packaging/hudi-utilities-bundle

RUN cp packaging/hudi-spark-bundle/target/hudi-spark3-bundle_2.12-0.10.0.jar /opt/spark/dist/jars/; \
  cp packaging/hudi-utilities-bundle/target/hudi-utilities-bundle_2.12-0.10.0.jar /opt/spark/dist/jars/

ENV DIRNAME=spark-${SPARK_VERSION}-glue-hudi

WORKDIR /opt/spark

RUN echo "Creating archive $DIRNAME.tgz"

RUN tar -cvzf "$DIRNAME.tgz" dist

FROM openjdk:8-jre-slim

RUN apt update; \
  apt install -y python3 python3-pip

COPY --from=builder /opt/spark/dist /opt/spark

WORKDIR /opt/spark

RUN rm -r data examples

ENV SPARK_HOME=/opt/spark
ENV PATH=${PATH}:${SPARK_HOME}/bin:${SPARK_HOME}/sbin
ENV PYTHONPATH=${PYTHONPATH}:${SPARK_HOME}/python:${SPARK_HOME}/python/lib/py4j-0.10.9-src.zip
