FROM perl:5.44-slim

WORKDIR /opt/urupam

RUN cpanm --notest Carton
COPY . ./

RUN carton install --deployment --without test

RUN useradd -m -u 10001 urupam \
  && chown -R urupam:urupam /opt/urupam

USER urupam

ENV MOJO_MODE=production
EXPOSE 8080

CMD ["carton", "exec", "--", "hypnotoad", "-f", "/opt/urupam/bin/urupam"]
