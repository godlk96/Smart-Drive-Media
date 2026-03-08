/**
 * (调度员) 一个简单的任务队列，确保耗时操作按顺序执行，不卡死程序。
 */
export class TaskRunner {
  #tail = Promise.resolve()

  run(task) {
    const execute = async () => task()
    this.#tail = this.#tail.then(execute, execute)
    return this.#tail
  }
}
