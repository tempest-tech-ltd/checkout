const core = require('@actions/core');
const exec = require('@actions/exec');

async function run() {
  try {
    const project = core.getInput('project');
    const referenceDirectory = core.getInput('common-path') || `${project}.git`;
    const targetDirectory = core.getInput('path');
    const targetReference = core.getInput('ref');
    const clean = core.getInput('clean') === 'true';

    let cmd = `bash git-checkout.sh --debug --project "${project}" --ref-dir "${referenceDirectory}"`
    if (targetDirectory) {
      cmd += ` --target-dir "${targetDirectory}"`
    }
    if (targetReference) {
      cmd += ` --target-ref "${targetReference}"`
    }
    if (clean) {
      cmd += ' --clean'
    }

    await exec.exec(`echo ${cmd}`);
  } catch (error) {
    core.setFailed(error.message);
  }
}

run();
