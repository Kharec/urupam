FROM perl:5.42

WORKDIR /opt/urupam

RUN cpanm --notest Carton
COPY . ./

RUN rm -rf /opt/urupam/local \
  && carton install --deployment --without test

COPY bin lib ./

RUN useradd -m -u 10001 urupam \
  && chown -R urupam:urupam /opt/urupam

USER urupam

ENV MOJO_MODE=production
EXPOSE 8080

CMD ["carton", "exec", "--", "hypnotoad", "-f", "/opt/urupam/bin/urupam"]
