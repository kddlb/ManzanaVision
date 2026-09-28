// SPDX-License-Identifier: GPL-2.0-only
/*
 * Signal-finder tone on AudioQueue. The meter thread only sets a target
 * pitch and mode; the audio callback glides towards the pitch and shapes
 * the envelope so changes never click.
 */
#include "tone.h"

#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>

#define SAMPLE_RATE 44100.0
#define FRAMES_PER_BUFFER 1024
#define NUM_BUFFERS 3
#define VOLUME 0.2
#define GLIDE 0.0015		/* per-sample approach towards the target pitch */
#define RAMP 0.002		/* per-sample envelope change (~11 ms fade) */
#define PULSE_ON_S 0.08
#define PULSE_PERIOD_S 0.25

static AudioQueueRef queue;
static _Atomic float target_hz = 440.0f;
static _Atomic int target_mode = TONE_SILENT;

/* audio-thread state */
static double phase, cur_hz = 440.0, env;
static unsigned long sample_clock;

static void fill(void *user, AudioQueueRef q, AudioQueueBufferRef buf)
{
	float *out = buf->mAudioData;
	double want_hz = atomic_load(&target_hz);
	int mode = atomic_load(&target_mode);

	(void)user;
	for (int i = 0; i < FRAMES_PER_BUFFER; i++) {
		double t = fmod(sample_clock++ / SAMPLE_RATE, PULSE_PERIOD_S);
		double want_env = mode == TONE_STEADY ? 1.0 :
				  mode == TONE_PULSED && t < PULSE_ON_S ? 1.0 : 0.0;

		cur_hz += (want_hz - cur_hz) * GLIDE;
		if (env < want_env)
			env = fmin(want_env, env + RAMP);
		else if (env > want_env)
			env = fmax(want_env, env - RAMP);

		out[i] = (float)(sin(phase) * env * VOLUME);
		phase += 2.0 * M_PI * cur_hz / SAMPLE_RATE;
		if (phase > 2.0 * M_PI)
			phase -= 2.0 * M_PI;
	}
	buf->mAudioDataByteSize = FRAMES_PER_BUFFER * sizeof(float);
	AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

int tone_start(void)
{
	AudioStreamBasicDescription fmt = {
		.mSampleRate = SAMPLE_RATE,
		.mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
		.mBytesPerPacket = sizeof(float),
		.mFramesPerPacket = 1,
		.mBytesPerFrame = sizeof(float),
		.mChannelsPerFrame = 1,
		.mBitsPerChannel = 32,
	};
	OSStatus err;

	/* NULL run loop: callbacks come on AudioQueue's own thread */
	err = AudioQueueNewOutput(&fmt, fill, NULL, NULL, NULL, 0, &queue);
	if (err) {
		fprintf(stderr, "tone: cannot open audio output (%d)\n", (int)err);
		return -1;
	}
	for (int i = 0; i < NUM_BUFFERS; i++) {
		AudioQueueBufferRef buf;

		if (AudioQueueAllocateBuffer(queue, FRAMES_PER_BUFFER * sizeof(float), &buf))
			break;
		fill(NULL, queue, buf);
	}
	err = AudioQueueStart(queue, NULL);
	if (err) {
		fprintf(stderr, "tone: cannot start audio (%d)\n", (int)err);
		AudioQueueDispose(queue, true);
		queue = NULL;
		return -1;
	}
	return 0;
}

void tone_stop(void)
{
	if (!queue)
		return;
	AudioQueueStop(queue, true);
	AudioQueueDispose(queue, true);
	queue = NULL;
}

void tone_set(double hz, enum tone_mode mode)
{
	atomic_store(&target_hz, (float)hz);
	atomic_store(&target_mode, mode);
}
