FROM lamw/vibauthor

# Copy all files to the container
COPY . letsencrypt-esxi

# Run VIB build script
RUN /bin/sh letsencrypt-esxi/build/create_vib.sh

CMD ["/bin/sh"]
