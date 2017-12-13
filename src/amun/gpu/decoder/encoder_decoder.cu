// -*- mode: c++; tab-width: 2; indent-tabs-mode: nil -*-
#include <iostream>

#include "common/god.h"
#include "common/sentences.h"
#include "common/histories.h"
#include "common/search.h"

#include "encoder_decoder.h"
#include "enc_out_gpu.h"
#include "gpu/mblas/matrix_functions.h"
#include "gpu/dl4mt/dl4mt.h"
#include "gpu/decoder/encoder_decoder_state.h"
#include "gpu/decoder/best_hyps.h"
#include "gpu/dl4mt/cellstate.h"


using namespace std;

namespace amunmt {
namespace GPU {

std::unordered_map<std::string, boost::timer::cpu_timer> timers;

EncoderDecoder::EncoderDecoder(
		const God &god,
		const std::string& name,
        const YAML::Node& config,
        size_t tab,
        const Weights& model)
  : Scorer(god, name, config, tab),
    model_(model),
    encoder_(new Encoder(model_, config)),
    decoder_(new Decoder(god, model_, config)),
    encDecBuffer_(god.Get<size_t>("encoder-buffer-size"))
{
  BEGIN_TIMER("EncoderDecoder");
}

EncoderDecoder::~EncoderDecoder()
{
  PAUSE_TIMER("EncoderDecoder");

  if (timers.size()) {
    boost::timer::nanosecond_type encDecWall = timers["EncoderDecoder"].elapsed().wall;

    cerr << "timers:" << endl;
    for (auto iter = timers.begin(); iter != timers.end(); ++iter) {
      const boost::timer::cpu_timer &timer = iter->second;
      boost::timer::cpu_times t = timer.elapsed();
      boost::timer::nanosecond_type wallTime = t.wall;

      int percent = (float) wallTime / (float) encDecWall * 100.0f;

      cerr << iter->first << " ";

      for (int i = 0; i < ((int)35 - (int)iter->first.size()); ++i) {
        cerr << " ";
      }

      cerr << timer.format(2, "%w") << " (" << percent << ")" << endl;
    }
  }

}

std::shared_ptr<Histories> EncoderDecoder::Translate(Search &search, SentencesPtr sentences)
{
  boost::timer::cpu_timer timer;

  if (search.GetFilter()) {
    search.FilterTargetVocab(*sentences);
  }

  // encode
  Encode(sentences);
  StatePtr state(NewState());

  EncOutPtr encOut = encDecBuffer_.Get();

  BeginSentenceState(encOut, *state, sentences->size());


  StatePtr nextState(NewState());

  std::vector<uint> beamSizes(sentences->size(), 1);

  std::shared_ptr<Histories> histories(new Histories(*sentences, search.NormalizeScore()));
  Beam prevHyps = histories->GetFirstHyps();

  for (size_t decoderStep = 0; decoderStep < 3 * sentences->GetMaxLength(); ++decoderStep) {
    Decode(encOut, *state, *nextState, beamSizes);

    if (decoderStep == 0) {
      for (auto& beamSize : beamSizes) {
        beamSize = search.MaxBeamSize();
      }
    }
    //cerr << "beamSizes=" << Debug(beamSizes, 1) << endl;

    //bool hasSurvivors = CalcBeam(histories, beamSizes, prevHyps, *states[0], *nextStates[0]);
    bool hasSurvivors = CalcBeam(search.GetBestHyps(), histories, beamSizes, prevHyps, *state, *nextState, search.GetFilterIndices());
    if (!hasSurvivors) {
      break;
    }
  }

  CleanAfterTranslation();

  LOG(progress)->info("Search took {}", timer.format(3, "%ws"));
  return histories;
}

void EncoderDecoder::Encode(SentencesPtr source) {
  BEGIN_TIMER("Encode");
  EncOutPtr encOut(new EncOutGPU(source));

  encoder_->Encode(encOut, tab_);

  encDecBuffer_.Add(encOut);

  PAUSE_TIMER("Encode");
}

void EncoderDecoder::BeginSentenceState(EncOutPtr encOut, State& state, size_t batchSize) {
  //BEGIN_TIMER("BeginSentenceState");
  EDState& edState = state.get<EDState>();
  decoder_->EmptyState(encOut, edState.GetStates(), batchSize);

  decoder_->EmptyEmbedding(edState.GetEmbeddings(), batchSize);
  //PAUSE_TIMER("BeginSentenceState");
}

void EncoderDecoder::Decode(EncOutPtr encOut, const State& state, State& nextState, const std::vector<uint>& beamSizes)
{
  BEGIN_TIMER("Decode");
  const EDState& edstate = state.get<EDState>();
  EDState& ednextState = nextState.get<EDState>();

  decoder_->Decode(encOut,
                   ednextState.GetStates(),
                   edstate.GetStates(),
                   edstate.GetEmbeddings(),
                   beamSizes,
                   god_.UseFusedSoftmax());
  PAUSE_TIMER("Decode");
}

void EncoderDecoder::AssembleBeamState(const State& state,
                               const Beam& beam,
                               State& nextState) const
{
  //BEGIN_TIMER("AssembleBeamState");
  std::vector<uint> beamWords;
  std::vector<uint> beamStateIds;
  for (const HypothesisPtr &h : beam) {
     beamWords.push_back(h->GetWord());
     beamStateIds.push_back(h->GetPrevStateIndex());
  }
  //cerr << "beamWords=" << Debug(beamWords, 2) << endl;
  //cerr << "beamStateIds=" << Debug(beamStateIds, 2) << endl;

  const EDState& edState = state.get<EDState>();
  EDState& edNextState = nextState.get<EDState>();

  thread_local mblas::Vector<uint> indices;
  indices.newSize(beamStateIds.size());
  //cerr << "indices=" << indices.Debug(2) << endl;

  mblas::copy(beamStateIds.data(),
              beamStateIds.size(),
              indices.data(),
              cudaMemcpyHostToDevice);
  //cerr << "indices=" << mblas::Debug(indices, 2) << endl;

  CellState& outstates = edNextState.GetStates();
  const CellState& instates = edState.GetStates();

  mblas::Assemble(*(outstates.output), *(instates.output), indices);
  if (instates.cell->size() > 0) {
    mblas::Assemble(*(outstates.cell), *(instates.cell), indices);
  }
  //cerr << "edNextState.GetStates()=" << edNextState.GetStates().Debug(1) << endl;

  //cerr << "beamWords=" << Debug(beamWords, 2) << endl;
  decoder_->Lookup(edNextState.GetEmbeddings(), beamWords);
  //cerr << "edNextState.GetEmbeddings()=" << edNextState.GetEmbeddings().Debug(1) << endl;
  //PAUSE_TIMER("AssembleBeamState");
}

State* EncoderDecoder::NewState() const {
  return new EDState();
}

void EncoderDecoder::GetAttention(mblas::Matrix& Attention) {
  decoder_->GetAttention(Attention);
}

BaseMatrix& EncoderDecoder::GetProbs() {
  return decoder_->GetProbs();
}

void *EncoderDecoder::GetNBest()
{
  return &decoder_->GetNBest();
}

const BaseMatrix *EncoderDecoder::GetBias() const
{
  return decoder_->GetBias();
}

mblas::Matrix& EncoderDecoder::GetAttention() {
  return decoder_->GetAttention();
}

size_t EncoderDecoder::GetVocabSize() const {
  return decoder_->GetVocabSize();
}

void EncoderDecoder::Filter(const std::vector<uint>& filterIds) {
  decoder_->Filter(filterIds);
}

/////////////////////////////////////////////////////////////////////////////////////
// const-batch2
bool EncoderDecoder::CalcBeam(BestHypsBase &bestHyps,
                      std::shared_ptr<Histories>& histories,
                      std::vector<uint>& beamSizes,
                      Beam& prevHyps,
                      State& state,
                      State& nextState,
                      const Words &filterIndices)
{
  size_t batchSize = beamSizes.size();
  Beams beams(batchSize);
  bestHyps.CalcBeam(prevHyps, *this, filterIndices, beams, beamSizes);
  histories->Add(beams);

  Beam survivors;
  for (size_t batchId = 0; batchId < batchSize; ++batchId) {
    for (auto& h : beams[batchId]) {
      if (h->GetWord() != EOS_ID) {
        survivors.push_back(h);
      } else {
        --beamSizes[batchId];
      }
    }
  }

  if (survivors.size() == 0) {
    return false;
  }

  AssembleBeamState(nextState, survivors, state);

  //cerr << "survivors=" << survivors.size() << endl;
  prevHyps.swap(survivors);
  return true;

}

}
}

