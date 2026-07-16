FROM registry.redhat.io/redhat/redhat-operator-index:v4.18
USER 0
RUN rm -rf /configs/*
COPY configs/ /configs
RUN rm -rf /tmp/cache/*
RUN /bin/opm serve /configs --cache-dir=/tmp/cache --cache-only
USER 1001
EXPOSE 50051
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]
