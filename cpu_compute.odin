package main

import "core:sync"
import "core:thread"

Compute_Dims :: distinct [3]u64

Workgroup_Args :: struct {
	global_id: Compute_Dims,
	workgroup_id: Compute_Dims,
	workgroup_count: Compute_Dims,
	workgroup_size: Compute_Dims,
	tile_size: Compute_Dims,
}

Job :: struct {
	fn: proc(Workgroup_Args, rawptr),
	args: Workgroup_Args,
	wg: ^sync.Wait_Group,
	data: rawptr,
}

State :: enum u8 {
	None = 0,
	Terminate = 1,
}

Message :: union {
	[]Job,
	State,
}

Worker :: struct {
	thread: ^thread.Thread,
	channel: sync.Channel(Message, .Both),
}

@(thread_local, private="file") worker_idx: u64
local_worker_idx :: proc() -> u64 { return worker_idx }

worker_new :: proc(idx: u64) -> (worker: Worker) {
	worker.channel = sync.channel_make(Message)
	worker.thread = thread.create_and_start_with_poly_data2(
		worker.channel,
		idx,
		proc(channel: sync.Channel(Message, .Both), idx: u64) {
			worker_idx = idx

			loop: for {
				message := sync.channel_recv(channel)
				switch m in message {
				case []Job:
					for job in m {
						job.fn(job.args, job.data)
					}
					sync.wait_group_add(m[0].wg, -len(m))
				case State:
					if m == .Terminate {
						break loop
					}
				}
			}
		},
	)

	return worker
}

worker_free :: proc(worker: ^Worker) {
	thread.destroy(worker.thread)
	sync.channel_destroy(worker.channel)
}

Compute_Group :: struct {
	workers: [dynamic]Worker,
	jobs: [dynamic]Job,
}

compute_group_new :: proc(worker_count := 16) -> (group: Compute_Group) {
	for i in 0..<worker_count {
		append(&group.workers, worker_new(u64(i)))
	}
	group.jobs = make([dynamic]Job)

	return group
}

compute_group_free :: proc(group: ^Compute_Group) {
	for worker, i in group.workers {
		sync.channel_send(worker.channel, State.Terminate)
		worker_free(&group.workers[i])
	}

	delete(group.jobs)
	delete(group.workers)
}

compute :: proc(
	group: ^Compute_Group,
	total_size, workgroup_size: Compute_Dims,
	fn: proc(Workgroup_Args, rawptr),
	data: rawptr = nil)
{
	assert(total_size.x > 0 && total_size.y > 0 && total_size.z > 0 &&
		workgroup_size.x > 0 && workgroup_size.y > 0 && workgroup_size.z > 0,
	)

	wg: sync.Wait_Group
	sync.wait_group_init(&wg)
	defer sync.wait_group_destroy(&wg)

	dispatches := 1 + ((total_size - 1) / workgroup_size)
	dispatches_count := dispatches.x * dispatches.y * dispatches.z
	reserve(&group.jobs, int(dispatches_count))
	defer clear(&group.jobs)
	for k in 0..<dispatches[2] {
		for j in 0..<dispatches[1] {
			for i in 0..<dispatches[0] {
				global_id := workgroup_size * { i, j, k }
				temp := global_id + workgroup_size
				args := Workgroup_Args{
					global_id,
					{ i, j, k },
					dispatches,
					workgroup_size,
					workgroup_size - (temp / total_size) * (temp % total_size),
				}

				append(&group.jobs, Job{ fn, args, &wg, data })
			}
		}
	}

	sync.wait_group_add(&wg, int(dispatches.x * dispatches.y * dispatches.z))

	jobs_per_worker := len(group.jobs) / len(group.workers)
	remainder_jobs := len(group.jobs) % len(group.workers)
	for worker, i in group.workers {
		begin_offset := remainder_jobs
		end_offset := begin_offset
		if i < remainder_jobs {
			begin_offset = i
			end_offset = begin_offset + 1
		}

		begin := i * jobs_per_worker + begin_offset
		end := (i + 1) * jobs_per_worker + end_offset
		assert(begin < end)
		if begin < len(group.jobs) {
			sync.channel_send(worker.channel, group.jobs[begin:end])
		}
	}

	sync.wait_group_wait(&wg)
}
