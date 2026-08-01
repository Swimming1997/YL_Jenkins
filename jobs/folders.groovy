folder('Platform') {
    description('Jenkins platform administration and validation jobs.')
}

folder('Platform/Validation') {
    description('Non-business smoke checks for platform configuration.')
}

folder('XHSMedium') {
    description('XHSMedium pipelines. Jobs are introduced in later phases.')
}

[
    'CI': 'Continuous integration jobs.',
    'Regression': 'Scheduled and pre-release regression jobs.',
    'Release': 'Release candidate and manifest jobs; disabled until authorized.',
    'Deploy': 'Environment deployment jobs; disabled until authorized.',
    'Operations': 'Whitelisted operations jobs; disabled until authorized.'
].each { name, descriptionText ->
    folder("XHSMedium/${name}") {
        description(descriptionText)
    }
}

