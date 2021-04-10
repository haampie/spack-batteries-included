DOCKER ?= docker
CURL ?= curl
GO ?= go

all: spack.develop.x

# Build spack.x with the latest spack develop version as a tarball from github
spack.develop.x: runtime bootstrap-install-spack-develop spack.x

# Build spack.x but don't download a new version of spack itself from github
spack.x: runtime bootstrap spack.x-quick

# Just rebuild spack.x file without rebuilding the runtime / bootstrap bits.
spack.x-quick: squashfs
	cat appimage-runtime/runtime output/spack.squashfs > output/spack.x
	chmod +x output/spack.x

# Build a docker image with an old version of glibc
docker: docker/Dockerfile
	DOCKER_BUILDKIT=1 $(DOCKER) build --progress=plain -t spack-old-glibc docker/

squashfs: docker
	rm -f output/spack.squashfs
	$(DOCKER) run --rm -v $(CURDIR)/appimage-runtime:/appimage-runtime \
	                -v $(CURDIR)/bootstrap-spack:/bootstrap-spack \
					-v $(CURDIR)/output:/output \
					-w /output spack-old-glibc \
					/appimage-runtime/view/bin/mksquashfs \
					/bootstrap-spack spack.squashfs


# A Go tool that allows you to rewrite symlinks, rpaths and runpaths
# and make all relative with respect to the root of the bootstrap folder.
env-tools: env-tools/make_relative_env.go
	$(GO) build -ldflags "-s -w" -o env-tools/make_relative_env env-tools/make_relative_env.go

# Create a runtime executable for AppImage (using zstd and dynamic linking against libfuse)
runtime: docker appimage-runtime/spack.yaml
	$(DOCKER) run --rm -v $(CURDIR)/appimage-runtime:/appimage-runtime -w /appimage-runtime spack-old-glibc spack --color=always -e . external find --not-buildable libfuse pkg-config cmake autoconf automake libtool m4
	$(DOCKER) run --rm -v $(CURDIR)/appimage-runtime:/appimage-runtime -w /appimage-runtime spack-old-glibc spack --color=always -e . concretize -f
	$(DOCKER) run --rm -v $(CURDIR)/appimage-runtime:/appimage-runtime -w /appimage-runtime spack-old-glibc spack --color=always -e . install -v
	$(DOCKER) run --rm -v $(CURDIR)/appimage-runtime:/appimage-runtime -w /appimage-runtime spack-old-glibc make clean
	$(DOCKER) run --rm -v $(CURDIR)/appimage-runtime:/appimage-runtime -w /appimage-runtime -e C_INCLUDE_PATH=/appimage-runtime/view/include -e LIBRARY_PATH=/appimage-runtime/view/lib spack-old-glibc make

# Install spack's own dependencies using the docker image, remove its build dependencies
# and remove static libaries too. Then try to make all paths relative using the Go script.
bootstrap: docker env-tools/make_relative_env bootstrap-spack/spack.yaml
	$(DOCKER) run --rm -e SSL_CERT_DIR=/etc/ssl/certs/ -v $(CURDIR)/bootstrap-spack:/bootstrap-spack -w /bootstrap-spack spack-old-glibc spack --color=always -e . install --fail-fast -v
	$(DOCKER) run --rm -v $(CURDIR)/bootstrap-spack:/bootstrap-spack -w /bootstrap-spack spack-old-glibc spack --color=always -e . gc -y
	$(DOCKER) run --rm -v $(CURDIR)/bootstrap-spack:/bootstrap-spack -w /bootstrap-spack spack-old-glibc bash -c 'find . -iname "*.a" | xargs rm -f'
	$(DOCKER) run --rm -v $(CURDIR)/bootstrap-spack:/bootstrap-spack -v $(CURDIR)/env-tools:/env-tools -w /bootstrap-spack spack-old-glibc /env-tools/make_relative_env . view install

# Download the latest version of spack as a tarball from GitHub
bootstrap-install-spack-develop: bootstrap
	rm -rf bootstrap-spack/spack
	mkdir bootstrap-spack/spack
	curl -Ls "https://api.github.com/repos/spack/spack/tarball/develop" | tar --strip-components=1 -xz -C bootstrap-spack/spack

clean:
	rm -f output/spack.x output/spack.squashfs