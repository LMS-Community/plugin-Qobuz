// ==UserScript==
// @match http://www.qobuz.com/album/*
// @match http://www.qobuz.com/telechargement-album-mp3/*
// @include http://www.qobuz.com/album/*
// @include http://www.qobuz.com/telechargement-album-mp3/*
//
// Pierre Beck 11/2012
//
// needs SqueezeboxQobuz plugin v1.70+
// http://forums.slimdevices.com/showthread.php?97146-Qobuz-com-streaming-plugin
// https://github.com/pierrepoulpe/SqueezeboxQobuz/downloads
//
// ==/UserScript==

//alert("Edit SqueezeboxQobuz.user.js before using it!"); return; // delete this line, uncomment and edit the next one
const squeezeBoxServer = "192.168.0.19:9000";
const multiPlayerSuffix = ""; //"&player=04:00:20:12:45:AB"

var albumIdentifier = document.querySelector('meta[itemprop="identifier"]').content.split(":")[1];
var listenButton = document.querySelector("div.product-action-box > div.action-line > div.action-listen > ul.dropdown-menu");
var listenButtonLiDivider = document.querySelector("div.product-action-box > div.action-line > div.action-listen > ul.dropdown-menu > li.divider");
var newOptionLi = document.createElement("li");
var newA = document.createElement("a");
newA.href="#";

var language = window.navigator.language.substr(0,2);
switch (language) {
case "fr":
  newA.innerHTML = "avec la SqueezeBox";	break;
default:
	newA.innerHTML = "with the SqueezeBox";	break;
}

newA.onclick = function(){
	var iframe = document.createElement("iframe");
	iframe.style.display = "none";
	iframe.src = "http://" + squeezeBoxServer + "/status.html?p0=qobuz&p1=playalbum&p2=" + albumIdentifier + multiPlayerSuffix;
	this.parentNode.appendChild(iframe);
	return false;
};

newOptionLi.appendChild(newA);
if (listenButtonLiDivider) {
	listenButton.insertBefore(newOptionLi, listenButtonLiDivider);
} else {
	listenButton.appendChild(newOptionLi);
}
