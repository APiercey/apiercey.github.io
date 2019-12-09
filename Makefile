install:
	bundle install

dev: install
	bundle exec jekyll serve --livereload --host 0.0.0.0

build: install
	bundle exec jekyll build
