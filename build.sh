#!/bin/sh

echo Preparing build...

if [ -e Qobuz ]; then
	rm -rf Qobuz/*
else
	mkdir Qobuz
fi

rm -f repo.xml*

cp * Qobuz/ &> /dev/null
cp -R HTML Qobuz/
rm -f Qobuz/*.zip Qobuz/*.sh* Qobuz/*.js

VERSION=`grep -o -E "version>(.*)</ver" install.xml | grep -o -E "[0-9]\.[0-9]+"`

ZIPFILE=Qobuz-$VERSION.zip

echo Packing files...
zip -9vr $ZIPFILE Qobuz -x *.sh* *.zip
echo ""

echo Creating repository file...
rm -rf Qobuz/

SHA=`shasum $ZIPFILE`

wget --no-check-certificate -q http://www.pierrebeck.fr/SqueezeboxQobuz/repo.xml

if [ -e repo.xml ]; then
	# create updated repo.xml file
	cp -f repo.xml repo.xml.bak
	SHA=`echo "$SHA" | awk {'print $1'}`
	cat repo.xml | sed -e "s/sha>.*</sha>$SHA</g" | sed -e "s/\(version=\"\)[^\"]*\(\" .*\)/\1$VERSION\2/g" | sed -e "s/Qobuz-.*zip/$ZIPFILE/" > repo.new
	mv -f repo.new repo.xml
	echo ""
	cat repo.xml
	
	echo $ZIPFILE and an updated repo.xml have been created. Please upload.
else
	echo $SHA
fi
echo ""
