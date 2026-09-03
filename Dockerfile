# Запуск без установки Ruby на машину:
#   docker build -t payout_router .
#   docker run --rm -v "$PWD/out:/app/out" payout_router route --out out
#   docker run --rm -p 8080:8080 payout_router serve --host 0.0.0.0
FROM ruby:4.0-slim

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without "development test" && bundle install --jobs 4

COPY . .
ENTRYPOINT ["ruby", "-Ilib", "bin/payout_router"]
CMD ["route", "--out", "out"]
