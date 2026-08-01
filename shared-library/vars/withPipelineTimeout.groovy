def call(Map config = [:], Closure body) {
    int minutes = (config.minutes ?: 30) as int
    if (minutes < 1 || minutes > 360) {
        error('withPipelineTimeout minutes must be between 1 and 360')
    }
    timeout(time: minutes, unit: 'MINUTES') {
        body()
    }
}
