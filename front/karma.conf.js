// Karma configuration file, see link for more information
// https://karma-runner.github.io/1.0/config/configuration-file.html

module.exports = function (config) {
  config.set({
    basePath: "",
    frameworks: ["jasmine", "@angular-devkit/build-angular"],
    plugins: [
      require("karma-jasmine"),
      require("karma-chrome-launcher"),
      require("karma-jasmine-html-reporter"),
      require("karma-coverage"),
      require("karma-junit-reporter"),
      require("@angular-devkit/build-angular/plugins/karma"),
    ],
    client: {
      jasmine: {
        // you can add configuration options for Jasmine here
        // the possible options are listed at https://jasmine.github.io/api/edge/Configuration.html
        // for example, you can disable the random execution with `random: false`
        // or set a specific seed with `seed: 4321`
      },
      clearContext: false, // leave Jasmine Spec Runner output visible in browser
    },
    jasmineHtmlReporter: {
      suppressAll: true, // removes the duplicated traces
    },
    coverageReporter: {
      dir: require("path").join(__dirname, "./coverage/microcrm"),
      subdir: ".",
      // lcov : rapport lu par SonarQube Cloud
      reporters: [{ type: "html" }, { type: "text-summary" }, { type: "lcovonly" }],
    },
    // Rapport JUnit XML publié dans GitHub Actions
    junitReporter: {
      outputDir: require("path").join(__dirname, "./test-results"),
      useBrowserName: false,
    },
    reporters: ["progress", "kjhtml"],
    browsers: ["ChromeHeadlessNoSandbox", "ChromeHeadless", "Chrome"],
    customLaunchers: {
      ChromeHeadlessNoSandbox: {
        base: "ChromeHeadless",
        flags: ["--no-sandbox"],
      },
    },
    restartOnFileChange: true,
  });
};
