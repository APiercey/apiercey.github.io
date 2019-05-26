JEKYLL_VERSION = 3.8

dev: 
	docker run -p 4000:4000 --rm \
  --volume="$(PWD):/srv/jekyll" \
  -it jekyll/jekyll:$(JEKYLL_VERSION) \
  jekyll serve --host 0.0.0.0

build: 
	docker run --rm \
  --volume="$(PWD):/srv/jekyll" \
  -it jekyll/builder:$(JEKYLL_VERSION) \
  jekyll build
