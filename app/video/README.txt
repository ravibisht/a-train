Background clip for the dashboard: app/video/atrain.mp4 (gitignored).
build.sh runs fetch.sh, which downloads "A-Train Status Greenscreen" by The Mining Meteor
(YouTube 3nxXwfkTkuU) with yt-dlp (brew install yt-dlp) the first time. The creator asks for credit,
which the dashboard footer shows. The app keys the green to its navy and plays it muted, looping.
No yt-dlp, or ATRAIN_NO_VIDEO=1: the app and DMG are built without the video and work the same.
To use a different clip, put any green-screen mp4 at app/video/atrain.mp4 before building.
