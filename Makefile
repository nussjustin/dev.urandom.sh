default:
	hugo --minify
	# find public -type f -not -name '*.br' -not -name '*.gz' -exec brotli -9 -f -k {} \;
	find public -type f -not -name '*.br' -not -name '*.gz' -exec gzip -9 -f -k {} \;
