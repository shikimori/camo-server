FROM node:20-alpine

RUN apt-get update && apt-get install -yq nodejs npm

RUN mkdir /app
WORKDIR /app

ADD package.json /app/
RUN npm install -g npm && npm install

ADD server.js /app/
ADD mime-types.json /app/

EXPOSE 8081
USER nobody
CMD nodejs server.js
