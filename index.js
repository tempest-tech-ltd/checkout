const core = require('@actions/core');
const exec = require('@actions/exec');
const github = require('@actions/github');

async function run() {
  try {
    const repository = core.getInput('repository') || github.context.repo.repo;
    const referenceDirectory = core.getInput('common-path') || `${repository}.git`;
    const targetDirectory = core.getInput('path');
    const targetReference = core.getInput('ref');
    const clean = core.getInput('clean') === 'true';

    let cmd = `${__dirname}/git-checkout.sh --debug --repo "${repository}" --ref-dir "${referenceDirectory}"`
    if (targetDirectory) {
      cmd += ` --target-dir "${targetDirectory}"`
    }
    if (targetReference) {
      cmd += ` --target-ref "${targetReference}"`
    }
    if (clean) {
      cmd += ' --clean'
    }
    if (process.platform === 'win32') {
      cmd = 'bash ' + cmd
    }

    await exec.exec(`echo ${cmd}`);
  } catch (error) {
    core.setFailed(error.message);
  }
}

run();
