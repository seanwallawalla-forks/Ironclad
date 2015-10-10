include "../../Common/Framework/Main.s.dfy"
include "../../Impl/LiveSHT/Host.i.dfy"
include "../../Common/Collections/Maps2.s.dfy"
include "../../Protocol/SHT/RefinementProof/RefinementProof.i.dfy"
include "../../Protocol/Common/NodeIdentity.i.dfy"
include "../../Protocol/LiveSHT/RefinementProof/SHTLemmas.i.dfy"
include "Marshall.i.dfy"
include "../../Protocol/SHT/Network.i.dfy"

module Main_i exclusively refines Main_s {
    import opened Host_i
    import opened Collections__Maps2_s
    import opened SHT__RefinementProof_i
    import opened Concrete_NodeIdentity_i
    import opened RefinementProof__DistributedSystemLemmas_i
    import opened MarshallProof_i
    import opened SHT__Network_i

    predicate IsValidBehavior(config:ConcreteConfiguration, db:seq<DS_State>)
        reads *;
    {
           |db| > 0
        && DS_Init(db[0], config)
        && forall i :: 0 <= i < |db| - 1 ==> DS_Next(db[i], db[i+1])
    }

    predicate LPacketIsAbstractable(cp:LPacket<EndPoint,seq<byte>>)
    {
        CSingleMessageIsAbstractable(SHTDemarshallData(cp.msg))
    }

    function AbstractifyConcretePacket(p:LPacket<EndPoint,seq<byte>>) : LPacket<NodeIdentity, SingleMessage<Message>>
        requires LPacketIsAbstractable(p);
    {
        LPacket(p.dst, p.src, AbstractifyCSingleMessageToSingleMessage(SHTDemarshallData(p.msg)))
    }

    predicate LEnvStepIsAbstractable(step:LEnvStep<EndPoint,seq<byte>>)
    {
        match step {
            case LEnvStepHostIos(actor, ios) => UdpEventLogIsAbstractable(ios)
            case LEnvStepDeliverPacket(p) => LPacketIsAbstractable(p)
            case LEnvStepAdvanceTime => true
            case LEnvStepStutter => true 
        }
    }

    function AbstractifyConcreteEnvStep(step:LEnvStep<EndPoint,seq<byte>>) : LEnvStep<NodeIdentity, SingleMessage<Message>>
        requires LEnvStepIsAbstractable(step);
    {
        match step {
            case LEnvStepHostIos(actor, ios) => LEnvStepHostIos(actor, AbstractifyRawLogToIos(ios))
            case LEnvStepDeliverPacket(p) => LEnvStepDeliverPacket(AbstractifyConcretePacket(p))
            case LEnvStepAdvanceTime => LEnvStepAdvanceTime()
            case LEnvStepStutter => LEnvStepStutter() 
        }
    }

    predicate ConcreteEnvironmentIsAbstractable(ds_env:LEnvironment<EndPoint,seq<byte>>)
    {
        (forall p :: p in ds_env.sentPackets ==> LPacketIsAbstractable(p))
     && LEnvStepIsAbstractable(ds_env.nextStep)
    }

    function AbstractifyConcreteSentPackets(sent:set<LPacket<EndPoint,seq<byte>>>) : set<LPacket<NodeIdentity, SingleMessage<Message>>>
        requires forall p :: p in sent ==> LPacketIsAbstractable(p);
    {
        set p | p in sent :: AbstractifyConcretePacket(p)
    }

    function AbstractifyConcreteEnvironment(ds_env:LEnvironment<EndPoint,seq<byte>>) : LEnvironment<NodeIdentity, SingleMessage<Message>>
        requires ConcreteEnvironmentIsAbstractable(ds_env);
    {
        LEnvironment(ds_env.time,
                     AbstractifyConcreteSentPackets(ds_env.sentPackets),
                     map [],
                     AbstractifyConcreteEnvStep(ds_env.nextStep))
    }

    function AbstractifyConcreteConfiguration(ds_config:ConcreteConfiguration) : SHTConfiguration
        requires ConstantsStateIsValid(ds_config);
    {
        AbstractifyToConfiguration( 
                                SHTConcreteConfiguration(
                                                        ds_config.hostIds,
                                                        ds_config.rootIdentity,
                                                        ds_config.params
                                                        )
                              )
    }

    function AbstractifyConcreteReplicas(replicas:map<EndPoint,HostState>, replica_order:seq<EndPoint>) : seq<LScheduler>
        requires forall r :: r in replica_order ==> r in replicas;
        ensures  |AbstractifyConcreteReplicas(replicas, replica_order)| == |replica_order|;
        ensures  forall i :: 0 <= i < |replica_order| ==> 
                 AbstractifyConcreteReplicas(replicas, replica_order)[i] == replicas[replica_order[i]].sched;
    {
        if replica_order == [] then []
        else
            [replicas[replica_order[0]].sched] + AbstractifyConcreteReplicas(replicas, replica_order[1..])
    }

    function AbstractifyConcreteClients(clients:set<EndPoint>) : set<NodeIdentity>
    {
        set e | e in clients :: e
    }

    predicate DsStateIsAbstractable(ds:DS_State) 
    {
           ConstantsStateIsValid(ds.config)
        && ConcreteEnvironmentIsAbstractable(ds.environment)
        && (forall r :: r in ds.config.hostIds ==> r in ds.servers)
    }

    function AbstractifyDsState(ds:DS_State) : LSHT_State
        requires DsStateIsAbstractable(ds);
    {
        LSHT_State(AbstractifyConcreteConfiguration(ds.config),
                    AbstractifyConcreteEnvironment(ds.environment),
                    AbstractifyConcreteReplicas(ds.servers, ds.config.hostIds))
    }

    lemma lemma_DeduceTransitionFromDsBehavior(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db| - 1;
        ensures  DS_Next(db[i], db[i+1]);
    {
    }
    
    lemma lemma_DsNextOffset(db:seq<DS_State>, index:int)
        requires |db| > 0;
        requires 0 < index < |db|;
        requires forall i :: 0 <= i < |db| - 1 ==> DS_Next(db[i], db[i+1]);
        ensures  DS_Next(db[index-1], db[index]);
    {
        var i := index - 1;
        assert DS_Next(db[i], db[i+1]); // OBSERVE trigger for the forall
    }

    lemma lemma_DsConsistency(config:ConcreteConfiguration, db:seq<DS_State>, i:int)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        ensures  db[i].config == config;
        ensures  Collections__Maps2_s.mapdomain(db[i].servers) == Collections__Maps2_s.mapdomain(db[0].servers);
        ensures  db[i].clients == db[0].clients;
    {
        if i == 0 {
        } else {
            lemma_DsConsistency(config, db, i-1);
            lemma_DeduceTransitionFromDsBehavior(config, db, i-1);

            assert forall server :: server in db[i-1].servers ==> server in db[i].servers;
            assert forall server :: server in db[i].servers ==> server in db[i-1].servers;

            forall server | server in Collections__Maps2_s.mapdomain(db[i-1].servers)
                ensures server in Collections__Maps2_s.mapdomain(db[i].servers)
            {
                assert server in db[i-1].servers;
                assert server in db[i].servers;
            }

            forall server | server in Collections__Maps2_s.mapdomain(db[i].servers)
                ensures server in Collections__Maps2_s.mapdomain(db[i-1].servers)
            {
                assert server in db[i].servers;
                assert server in db[i-1].servers;
            }
        }
    }
    
    lemma lemma_HostIdsConsistent(config:ConcreteConfiguration, db:seq<DS_State>, i:int, id:EndPoint, query:EndPoint)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires id in db[i].servers;
        ensures  query in db[i].servers[id].sched.host.constants.hostIds <==> query in config.hostIds;
    {
        lemma_DsConsistency(config, db, i);  // ==> db[i].config == config
        if i == 0 {
            assert query in db[i].servers[id].sched.host.constants.hostIds <==> query in config.hostIds;
        } else {
            assert id in db[i].servers <==> id in Collections__Maps2_s.mapdomain(db[i].servers);      // OBSERVE
            assert id in db[i-1].servers <==> id in Collections__Maps2_s.mapdomain(db[i-1].servers);  // OBSERVE
            calc {
                Collections__Maps2_s.mapdomain(db[i].servers);
                Collections__Maps2_s.mapdomain(db[0].servers);
                    { lemma_DsConsistency(config, db, i-1);  }
                Collections__Maps2_s.mapdomain(db[i-1].servers);
            }
            lemma_HostIdsConsistent(config, db, i-1, id, query);
            lemma_DeduceTransitionFromDsBehavior(config, db, i-1);
        }
    }


    lemma lemma_PacketSentByServerIsMarshallable(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        p:LPacket<EndPoint, seq<byte>>
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires p.src in config.hostIds;
        requires p in db[i].environment.sentPackets;
        ensures  UdpPacketBound(p.msg);
        ensures  CSingleMessageMarshallable(SHTDemarshallData(p.msg));
    {
        if i == 0 {
            return;
        }

        if p in db[i-1].environment.sentPackets {
            lemma_PacketSentByServerIsMarshallable(config, db, i-1, p);
            return;
        }

        lemma_DeduceTransitionFromDsBehavior(config, db, i-1);
        lemma_DsConsistency(config, db, i-1);
        assert LEnvironment_Next(db[i-1].environment, db[i].environment);
        assert db[i-1].environment.nextStep.LEnvStepHostIos?;
        var io := LIoOpSend(p);
        var ios := db[i-1].environment.nextStep.ios;
        assert io in ios;
        assert IsValidLIoOp(io, db[i-1].environment.nextStep.actor, db[i-1].environment);
        assert db[i-1].environment.nextStep.actor == p.src;
        assert DS_NextOneServer(db[i-1], db[i], p.src, ios);
        assert OnlySentMarshallableData(ios);
        assert UdpPacketBound(io.s.msg);
        assert CSingleMessageMarshallable(SHTDemarshallData(io.s.msg));
    }
    
    lemma lemma_BufferedPacketFindRawPacket(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        id:EndPoint
        )
        returns(p:LPacket<EndPoint, seq<byte>>)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires id in db[i].servers;
        requires db[i].servers[id].sched.host.receivedPacket.Some?;
        ensures  UdpPacketIsAbstractable(p);
        ensures  AbstractifyUdpPacketToShtPacket(p) == db[i].servers[id].sched.host.receivedPacket.v;
        ensures  p in db[i].environment.sentPackets;
        ensures  p.dst == id;
    {
        if i == 0 {
            return;
        }

        lemma_DeduceTransitionFromDsBehavior(config, db, i-1);
        lemma_DsConsistency(config, db, i-1);

        if db[i].servers[id].sched.host.receivedPacket == db[i-1].servers[id].sched.host.receivedPacket {
            p := lemma_BufferedPacketFindRawPacket(config, db, i-1, id);
            return;
        }

        assert db[i-1].environment.nextStep.actor == id;
        p := db[i-1].environment.nextStep.ios[0].r;
        assert IsValidLIoOp(db[i-1].environment.nextStep.ios[0], id, db[i-1].environment);
        assert p.dst == id;
    }


    lemma lemma_FindReceivedRequestStepHelper(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        id:EndPoint,
        req_index:int
        )
        returns (step_before:int, step_after:int)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires id in db[i].servers;
        requires 0 <= req_index < |db[i].servers[id].sched.host.receivedRequests|;
        ensures  0 <= step_before < step_after <= i;
        ensures  step_after == step_before + 1;
        ensures  id in db[step_before].servers;
        ensures  id in db[step_after].servers;
        ensures |db[step_before].servers[id].sched.host.receivedRequests| == req_index;
        ensures |db[step_after].servers[id].sched.host.receivedRequests| == req_index + 1;
    {
        if i == 0 {
            assert false;
        }

        lemma_DeduceTransitionFromDsBehavior(config, db, i-1);
        lemma_DsConsistency(config, db, i-1);

        if  db[i].servers[id].sched.host.receivedRequests == db[i-1].servers[id].sched.host.receivedRequests {
            step_before, step_after := lemma_FindReceivedRequestStepHelper(config, db, i-1, id, req_index);
            return;
        }

        assert |db[i].servers[id].sched.host.receivedRequests| == |db[i-1].servers[id].sched.host.receivedRequests| + 1;

        if |db[i-1].servers[id].sched.host.receivedRequests| > req_index {
            step_before, step_after := lemma_FindReceivedRequestStepHelper(config, db, i-1, id, req_index);
            return;
        }

        assert db[i-1].environment.nextStep.actor == id;
        step_before := i - 1;
        step_after := i;
    }

    lemma lemma_RecevedRequestsConsistent(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        j:int,
        id:EndPoint,
        req:AppRequest,
        req_index:int
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i <= j < |db|;
        requires id in db[i].servers;
        requires 0 <= req_index < |db[i].servers[id].sched.host.receivedRequests|;
        requires db[i].servers[id].sched.host.receivedRequests[req_index] == req;
        ensures  id in db[j].servers;
        ensures  0 <= req_index < |db[j].servers[id].sched.host.receivedRequests|;
        ensures  db[j].servers[id].sched.host.receivedRequests[req_index] == req;
    {
        lemma_DsConsistency(config, db, i);
        lemma_DsConsistency(config, db, j);
        if j == i {
            return;
        } else {
            lemma_DsNextOffset(db, j);
            lemma_DeduceTransitionFromDsBehavior(config, db, j-1);
            lemma_RecevedRequestsConsistent(config, db, i, j - 1, id, req, req_index);
        }
    }

    lemma lemma_FindReceivedRequestStep(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        id:EndPoint,
        req:AppRequest,
        req_index:int
        )
        returns (step_before:int, step_after:int)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires id in db[i].servers;
        requires 0 <= req_index < |db[i].servers[id].sched.host.receivedRequests|;
        requires db[i].servers[id].sched.host.receivedRequests[req_index] == req;
        ensures  0 <= step_before < step_after <= i;
        ensures  step_after == step_before + 1;
        ensures  id in db[step_before].servers;
        ensures  id in db[step_after].servers;
        ensures |db[step_before].servers[id].sched.host.receivedRequests| == req_index;
        ensures |db[step_after].servers[id].sched.host.receivedRequests| == req_index + 1;
        ensures db[step_after].servers[id].sched.host.receivedRequests[req_index] == req;
    {
        step_before, step_after := lemma_FindReceivedRequestStepHelper(config, db, i, id, req_index);
        if db[step_after].servers[id].sched.host.receivedRequests[req_index] != req {
            var req' := db[step_after].servers[id].sched.host.receivedRequests[req_index];
            lemma_RecevedRequestsConsistent(config, db, step_after, i, id, req', req_index);
        }
    }

    lemma lemma_FindRawAppGetRequest(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        id:EndPoint,
        req:AppRequest,
        req_index:int
        )
        returns (step:int)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires id in db[i].servers;
        requires 0 <= req_index < |db[i].servers[id].sched.host.receivedRequests|;
        requires db[i].servers[id].sched.host.receivedRequests[req_index] == req;
        requires req.AppGetRequest?;
        ensures  0 <= step <= i;
        ensures  id in db[step].servers;
        ensures  var h := db[step].servers[id].sched.host;
                    h.receivedPacket.Some?
                 && h.receivedPacket.v.msg.SingleMessage?
                 && h.receivedPacket.v.msg.m.GetRequest?
                 && req == AppGetRequest(h.receivedPacket.v.msg.seqno, h.receivedPacket.v.msg.m.k_getrequest);
    {
        var step_before, step_after := lemma_FindReceivedRequestStep(config, db, i, id, req, req_index);
        step := step_before;
    }
    
    lemma lemma_FindRawAppSetRequest(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        id:EndPoint,
        req:AppRequest,
        req_index:int
        )
        returns (step:int)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires id in db[i].servers;
        requires 0 <= req_index < |db[i].servers[id].sched.host.receivedRequests|;
        requires db[i].servers[id].sched.host.receivedRequests[req_index] == req;
        requires req.AppSetRequest?;
        ensures  0 <= step <= i;
        ensures  id in db[step].servers;
        ensures  var h := db[step].servers[id].sched.host;
                    h.receivedPacket.Some?
                 && h.receivedPacket.v.msg.SingleMessage?
                 && h.receivedPacket.v.msg.m.SetRequest?
                 && req == AppSetRequest(h.receivedPacket.v.msg.seqno, h.receivedPacket.v.msg.m.k_setrequest, h.receivedPacket.v.msg.m.v_setrequest);
    {
        var step_before, step_after := lemma_FindReceivedRequestStep(config, db, i, id, req, req_index);
        step := step_before;
    }
    
    lemma lemma_SentPacketIsValidPhysicalPacket(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        p:LPacket<EndPoint, seq<byte>>
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires p in db[i].environment.sentPackets;
        ensures  ValidPhysicalPacket(p);
    {
        if i == 0 {
            return;
        }

        if p in db[i-1].environment.sentPackets {
            lemma_SentPacketIsValidPhysicalPacket(config, db, i-1, p);
            return;
        }

        lemma_DeduceTransitionFromDsBehavior(config, db, i-1);
        assert LEnvironment_Next(db[i-1].environment, db[i].environment);
        assert db[i-1].environment.nextStep.LEnvStepHostIos?;
        var io := LIoOpSend(p);
        assert io in db[i-1].environment.nextStep.ios;
        assert ValidPhysicalEnvironmentStep(db[i-1].environment.nextStep);
    }
    
    lemma lemma_UdpEventIsAbstractable(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        udp_event:UdpEvent
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db| - 1;
        requires db[i].environment.nextStep.LEnvStepHostIos?;
        requires udp_event in db[i].environment.nextStep.ios;
        ensures  UdpEventIsAbstractable(udp_event);
    {
        if udp_event.LIoOpTimeoutReceive? || udp_event.LIoOpReadClock? {
            return;
        }

        lemma_DeduceTransitionFromDsBehavior(config, db, i);
        assert ValidPhysicalEnvironmentStep(db[i].environment.nextStep);
        assert ValidPhysicalIo(udp_event);
    }

    lemma lemma_DsIsAbstractable(config:ConcreteConfiguration, db:seq<DS_State>, i:int)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires LEnvStepIsAbstractable(last(db).environment.nextStep);
        ensures  DsStateIsAbstractable(db[i]);
    {
        lemma_DsConsistency(config, db, i);

        forall p | p in db[i].environment.sentPackets
            ensures LPacketIsAbstractable(p);
        {
            lemma_SentPacketIsValidPhysicalPacket(config, db, i, p);
        }

        if i == |db|-1
        {
            return;
        }

        var step := db[i].environment.nextStep;
        if step.LEnvStepHostIos? {
            forall io | io in step.ios
                ensures UdpEventIsAbstractable(io);
            {
                lemma_UdpEventIsAbstractable(config, db, i, io);
            }
            assert UdpEventLogIsAbstractable(step.ios);
        }
        else if step.LEnvStepDeliverPacket? {
            lemma_DeduceTransitionFromDsBehavior(config, db, i);
            assert IsValidLEnvStep(db[i].environment, step);
            assert step.p in db[i].environment.sentPackets;
            lemma_SentPacketIsValidPhysicalPacket(config, db, i, step.p);
        }
    }

    lemma lemma_IosRelations(ios:seq<LIoOp<EndPoint, seq<byte>>>, r_ios:seq<LIoOp<NodeIdentity, SingleMessage<Message>>>)
        returns (sends:set<LPacket<EndPoint, seq<byte>>>, r_sends:set<LPacket<NodeIdentity, SingleMessage<Message>>>) 
        requires UdpEventLogIsAbstractable(ios);
        requires forall io :: io in ios && io.LIoOpSend? ==> LPacketIsAbstractable(io.s);
        requires r_ios == AbstractifyRawLogToIos(ios);
        ensures    sends == (set io | io in ios && io.LIoOpSend? :: io.s);
        ensures  r_sends == (set io | io in r_ios && io.LIoOpSend? :: io.s);
        ensures  forall send :: send in sends ==> LPacketIsAbstractable(send);
        ensures  r_sends == AbstractifyConcreteSentPackets(sends);
    {
          sends := (set io | io in ios && io.LIoOpSend? :: io.s);
        r_sends := (set io | io in r_ios && io.LIoOpSend? :: io.s);
        var refined_sends := AbstractifyConcreteSentPackets(sends);

        forall r | r in refined_sends
            ensures r in r_sends;
        {
            var send :| send in sends && AbstractifyConcretePacket(send) == r;
            var io :| io in ios && io.LIoOpSend? && io.s == send;
            assert AbstractifyUdpEventToLSHTIo(io) in r_ios;
        }

        forall r | r in r_sends
            ensures r in refined_sends;
        {
            var r_io :| r_io in r_ios && r_io.LIoOpSend? && r_io.s == r; 
            var j :| 0 <= j < |r_ios| && r_ios[j] == r_io;
            assert AbstractifyUdpEventToLSHTIo(ios[j]) == r_io;
            assert ios[j] in ios;
            assert ios[j].s in sends;
        }
    }

    lemma lemma_IsValidEnvStep(de:LEnvironment<EndPoint, seq<byte>>, le:LEnvironment<NodeIdentity, SingleMessage<Message>>)
        requires IsValidLEnvStep(de, de.nextStep);
        requires de.nextStep.LEnvStepHostIos?;
        requires ConcreteEnvironmentIsAbstractable(de);
        requires AbstractifyConcreteEnvironment(de) == le;
        ensures  IsValidLEnvStep(le, le.nextStep);
    {
        var id := de.nextStep.actor;
        var ios := de.nextStep.ios;
        var r_ios := le.nextStep.ios;

        assert LIoOpSeqCompatibleWithReduction(r_ios);
            
        forall io | io in r_ios
            ensures IsValidLIoOp(io, id, le);
        {
            var j :| 0 <= j < |r_ios| && r_ios[j] == io;
            assert r_ios[j] == AbstractifyUdpEventToLSHTIo(ios[j]);
            assert IsValidLIoOp(ios[j], id, de);
        }
    }

    lemma lemma_LEnvironmentNextHost(de :LEnvironment<EndPoint, seq<byte>>, le :LEnvironment<NodeIdentity, SingleMessage<Message>>,
                                      de':LEnvironment<EndPoint, seq<byte>>, le':LEnvironment<NodeIdentity, SingleMessage<Message>>)
        requires ConcreteEnvironmentIsAbstractable(de);
        requires ConcreteEnvironmentIsAbstractable(de');
        requires AbstractifyConcreteEnvironment(de)  == le;
        requires AbstractifyConcreteEnvironment(de') == le';
        requires de.nextStep.LEnvStepHostIos?;
        requires LEnvironment_Next(de, de');
        ensures  LEnvironment_Next(le, le');
    {
        lemma_IsValidEnvStep(de, le);
        var id := de.nextStep.actor;
        var ios := de.nextStep.ios;
        var r_ios := le.nextStep.ios;

        assert LEnvironment_PerformIos(de, de', id, ios);

        var sends, r_sends := lemma_IosRelations(ios, r_ios);
        assert de.sentPackets + sends == de'.sentPackets;
        assert le.sentPackets + r_sends == le'.sentPackets;

        assert forall r_io :: r_io in r_ios && r_io.LIoOpReceive? ==> r_io.r in le.sentPackets;

        assert LEnvironment_PerformIos(le, le', id, r_ios);
    }

    predicate ReplicasDistinct(replica_ids:seq<NodeIdentity>, i:int, j:int)
    {
        0 <= i < |replica_ids| && 0 <= j < |replica_ids| && replica_ids[i] == replica_ids[j] ==> i == j
    }

    lemma lemma_LSchedulerNextPreservesConstants(
        s:LScheduler,
        s':LScheduler,
        ios:seq<LSHTIo>
        )
        requires LScheduler_Next(s, s', ios);
        ensures  s.host.constants == s.host.constants;
    {
    }

    lemma {:timeLimitMultiplier 2} lemma_AllConfigConsistent(config:ConcreteConfiguration, db:seq<DS_State>, i:int, s:LSHT_State)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires DsStateIsAbstractable(db[i]);
        requires s == AbstractifyDsState(db[i]);
        requires LEnvStepIsAbstractable(last(db).environment.nextStep);
        ensures  db[i].config == config;
        ensures  WFSHTConfiguration(s.config);
        ensures  forall k :: 0 <= k < |s.config.hostIds| ==> s.hosts[k].host.me == s.config.hostIds[k];
    {
        if i == 0
        {
            assert DS_Init(db[0], config);
            lemma_DsIsAbstractable(config, db, 0);
            var ls := AbstractifyDsState(db[0]);
            //sb := [ ls ];

            // Prove LSHT_MapsComplete
            calc {
                |ls.hosts|;
                |AbstractifyConcreteReplicas(db[0].servers, db[0].config.hostIds)|;
                |db[0].config.hostIds|;
                |AbstractifyEndPointsToNodeIdentities(db[0].config.hostIds)|;
                |AbstractifyToConstants(db[0].config).hostIds|;
                |ls.config.hostIds|;
            }
            var shtconcreteconfig := SHTConcreteConfiguration(
                                                        config.hostIds,
                                                        config.rootIdentity,
                                                        config.params
                                                        );
            assert SHTConcreteConfigurationIsAbstractable(shtconcreteconfig)
                && shtconcreteconfig.rootIdentity in shtconcreteconfig.hostIds
                && 0 < |shtconcreteconfig.hostIds|;
            lemma_WFSHTConcreteConfiguration(shtconcreteconfig);
            forall i | 0 <= i < |ls.config.hostIds|
                ensures ls.hosts[i].host.me == ls.config.hostIds[i];
            {
                reveal_SeqIsUnique();
            }
            return;
        }
        lemma_DsConsistency(config, db, i-1);
        lemma_DsConsistency(config, db, i);
        lemma_DeduceTransitionFromDsBehavior(config, db, i-1);
        forall k | 0 <= k < |s.config.hostIds| 
            ensures s.hosts[k].host.me == s.config.hostIds[k];
        {
            lemma_ConfigConsistent(config, db, i, k, s);
        }
        lemma_DsIsAbstractable(config, db, i-1);
        lemma_AllConfigConsistent(config, db, i-1, AbstractifyDsState(db[i-1]));
    }

    lemma {:timeLimitMultiplier 2} lemma_ConfigConsistent(config:ConcreteConfiguration, db:seq<DS_State>, i:int, k:int, s:LSHT_State)
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db|;
        requires DsStateIsAbstractable(db[i]);
        requires s == AbstractifyDsState(db[i]);
        requires LEnvStepIsAbstractable(last(db).environment.nextStep);
        requires 0 <= k < |s.config.hostIds|;
        ensures  s.hosts[k].host.me == s.config.hostIds[k];
    {
        var id := s.config.hostIds[k];
        assert id in db[i].servers;
        
        if i == 0
        {
            assert DS_Init(db[0], config);
            lemma_DsIsAbstractable(config, db, 0);
            var ls := AbstractifyDsState(db[0]);
            //sb := [ ls ];

            // Prove LSHT_MapsComplete
            calc {
                |ls.hosts|;
                |AbstractifyConcreteReplicas(db[0].servers, db[0].config.hostIds)|;
                |db[0].config.hostIds|;
                |AbstractifyEndPointsToNodeIdentities(db[0].config.hostIds)|;
                |AbstractifyToConstants(db[0].config).hostIds|;
                |ls.config.hostIds|;
            }
            var shtconcreteconfig := SHTConcreteConfiguration(
                                                        config.hostIds,
                                                        config.rootIdentity,
                                                        config.params
                                                        );
            assert SHTConcreteConfigurationIsAbstractable(shtconcreteconfig)
                && shtconcreteconfig.rootIdentity in shtconcreteconfig.hostIds
                && 0 < |shtconcreteconfig.hostIds|;
            lemma_WFSHTConcreteConfiguration(shtconcreteconfig);
            forall i | 0 <= i < |ls.config.hostIds|
                ensures ls.hosts[i].host.me == ls.config.hostIds[i];
            {
                reveal_SeqIsUnique();
            }
            return;
        }
        lemma_DsConsistency(config, db, i-1);
        lemma_DsConsistency(config, db, i);
        lemma_DeduceTransitionFromDsBehavior(config, db, i-1);

        assert Collections__Maps2_s.mapdomain(db[i].servers) == Collections__Maps2_s.mapdomain(db[0].servers) == Collections__Maps2_s.mapdomain(db[i-1].servers);
        lemma_DsIsAbstractable(config, db, i-1);
        //lemma_ConfigConsistent(config, db, i-1, db[i-1].environment.nextStep.actor);

        

        if db[i-1].servers == db[i].servers// && db[i-1].config.hostIds == db[i].config.hostIds
        {
            var acr := AbstractifyConcreteReplicas(db[i-1].servers, db[i-1].config.hostIds); 
            var acr' := AbstractifyConcreteReplicas(db[i].servers, db[i].config.hostIds); 
            var ls := AbstractifyDsState(db[i-1]);
            var ls' := AbstractifyDsState(db[i]);
            assert ls.hosts == acr;
            assert ls'.hosts == acr';
            assert acr == acr';
            assert ls.hosts == ls'.hosts;
            lemma_ConfigConsistent(config, db, i-1, k, AbstractifyDsState(db[i-1]));
            /*var lsPrior := AbstractifyDsState(db[i-1]);
            assert forall i :: 0 <= i < |lsPrior.config.hostIds| ==> lsPrior.hosts[i].host.me == lsPrior.config.hostIds[i];
            assert lsPrior == ls;*/
            return;
        }
        assert db[i-1].environment.nextStep.LEnvStepHostIos? && db[i-1].environment.nextStep.actor in db[i-1].servers;
        
        
        var sc := db[i-1].servers[db[i-1].environment.nextStep.actor].sched;
        var sc' := db[i].servers[db[i-1].environment.nextStep.actor].sched;
        
        assert DS_NextOneServer(db[i-1], db[i], db[i-1].environment.nextStep.actor, db[i-1].environment.nextStep.ios);
        assert db[i].servers == db[i-1].servers[db[i-1].environment.nextStep.actor := db[i].servers[db[i-1].environment.nextStep.actor]];
        var ios :| DS_NextOneServer(db[i-1], db[i], db[i-1].environment.nextStep.actor, ios);
        var rios := AbstractifyRawLogToIos(ios);
        //assert HostNext(s.servers[id], s'.servers[id], ios)
        assert LScheduler_Next(sc, sc', rios) || HostNextIgnoreUnsendable(sc, sc', ios);
        lemma_ConfigConsistent(config, db, i-1, k, AbstractifyDsState(db[i-1]));
        if LScheduler_Next(sc, sc', rios)
        {
            var ls := AbstractifyDsState(db[i-1]);
            var ls' := AbstractifyDsState(db[i]);
            
                assert ls'.hosts[k].host.me == ls.hosts[k].host.me;
                assert ls'.hosts == AbstractifyConcreteReplicas(db[i].servers, db[i].config.hostIds);
                assert AbstractifyConcreteReplicas(db[i].servers, db[i].config.hostIds)[k] == db[i].servers[db[i].config.hostIds[k]].sched;
                assert ls'.hosts[k] == db[i].servers[db[i].config.hostIds[k]].sched;
                assert ls.hosts[k] == db[i-1].servers[db[i-1].config.hostIds[k]].sched;
                assert ls'.config.hostIds[k] == ls.config.hostIds[k];
                if (ls.config.hostIds[k] != db[i-1].environment.nextStep.actor) {
                    assert ls'.hosts[k] == ls.hosts[k];
                } else {
                    assert ls'.hosts[k].host.me == ls'.config.hostIds[k];
                }
            
            //lemma_LSchedulerNextPreservesConstants(s, s', rios);
        }
        else
        {
            //assert s'.host == s.host;
        }
    }

    lemma lemma_RefinementOfUnsendablePacketHasLimitedPossibilities(
        p:LPacket<EndPoint, seq<byte>>,
        g:G,
        rp:LSHTPacket
        )
        requires g == CSingleMessage_grammar();
        requires ValidGrammar(g);
        requires !Demarshallable(p.msg, g) || !CSingleMessageMarshallable(parse_CSingleMessage(DemarshallFunc(p.msg, g)));
        requires UdpPacketIsAbstractable(p);
        requires rp == AbstractifyUdpPacketToLSHTPacket(p);
        ensures    rp.msg.InvalidMessage?
                || rp.msg.SingleMessage? //&& !rp.msg.m.GetRequest?)
    {
        assert !rp.msg.Ack?;
        if Demarshallable(p.msg, g) {
            var cmsg := parse_CSingleMessage(DemarshallFunc(p.msg, g));
            if cmsg.CSingleMessage? {
                assert !EndPointIsAbstractable(cmsg.dst) || !MessageMarshallable(cmsg.m);
            }
        }
    }

    lemma lemma_IgnoringUnsendableGivesEmptySentPackets(ios:seq<LSHTIo>)
        requires |ios| == 1;
        requires ios[0].LIoOpReceive?;
        ensures  ExtractPacketsFromLSHTPackets(ExtractSentPacketsFromIos(ios)) == {};
    {
        reveal_ExtractSentPacketsFromIos();
    }

    lemma lemma_IgnoringInvalidMessageIsLSchedulerNext(
        s:LScheduler,
        s':LScheduler,
        ios:seq<LSHTIo>
        )
        requires s.nextActionIndex == 0;
        requires s' == s[nextActionIndex := (s.nextActionIndex + 1) % LHost_NumActions()];
        requires |ios| == 1;
        requires ios[0].LIoOpReceive?;
        requires ios[0].r.msg.InvalidMessage?;
        requires DelegationMapComplete(s.host.delegationMap);
        ensures  LScheduler_Next(s, s', ios);
    {
        var sent_packets := ExtractPacketsFromLSHTPackets(ExtractSentPacketsFromIos(ios));
        lemma_IgnoringUnsendableGivesEmptySentPackets(ios);
        assert sent_packets == {};
        var packet := Packet(ios[0].r.dst, ios[0].r.src, ios[0].r.msg);
        var ack;
        assert ReceivePacket(s.host, s'.host, packet, sent_packets, ack);
        assert ReceivePacket_Wrapper(s.host, s'.host, packet, sent_packets);
        assert LHost_ReceivePacketWithoutReadingClock(s.host, s'.host, ios);
        assert LHost_ReceivePacket_Next(s.host, s'.host, ios);
    }

    lemma lemma_IgnoringCertainMessageTypesFromNonServerIsLSchedulerNext(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        id:EndPoint,
        s:LScheduler,
        s':LScheduler,
        ios:seq<LIoOp<EndPoint, seq<byte>>>
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db| - 1;
        requires id in db[i].servers;
        requires id in db[i+1].servers;
        requires DelegationMapComplete(s.host.delegationMap);
        requires DsStateIsAbstractable(db[i]);
        requires s == db[i].servers[id].sched;
        requires s' == db[i+1].servers[id].sched;
        requires s.nextActionIndex == 1;
        requires IgnoreSchedulerUpdate(s, s');
        requires IosReflectIgnoringUnParseable(s, ios);
        ensures  UdpEventLogIsAbstractable(ios);
        ensures  LScheduler_Next(s, s', AbstractifyRawLogToIos(ios));
    {
        assert |ios| == 0;
        assert UdpEventLogIsAbstractable([]);
        assert AbstractifyRawLogToIos([]) == [];
        if s.host.receivedPacket.v.src in s.host.constants.hostIds {
            // No real host would have sent such a mangled packet
            var p := lemma_BufferedPacketFindRawPacket(config, db, i, id);
            //lemma_AllConfigConsistent(config, db, i, AbstractifyDsState(db[i]));
            lemma_HostIdsConsistent(config, db, i, id, s.host.receivedPacket.v.src);
            lemma_PacketSentByServerIsMarshallable(config, db, i, p);
            assert false;
        } else {
            // We ignore delegate messages from non-hosts
            assert NextDelegate(s.host, s'.host, s.host.receivedPacket.v, {});
            assert Process_Message(s.host, s'.host, {});
            assert ProcessReceivedPacket(s.host, s'.host, {});
            assert Host_Next(s.host, s'.host, {}, {});
        }
    }

    lemma lemma_HostNextIgnoreUnsendableIsLSchedulerNext(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        id:EndPoint,
        ios:seq<LIoOp<EndPoint, seq<byte>>>
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db| - 1;
        requires db[i].environment.nextStep == LEnvStepHostIos(id, ios);
        requires id in db[i].servers;
        requires id in db[i+1].servers;
        requires DsStateIsAbstractable(db[i]);
        requires DelegationMapComplete(db[i].servers[id].sched.host.delegationMap);
        requires HostNextIgnoreUnsendable(db[i].servers[id].sched, db[i+1].servers[id].sched, ios);
        ensures  LScheduler_Next(db[i].servers[id].sched, db[i+1].servers[id].sched, AbstractifyRawLogToIos(ios));
    {
        var s := db[i].servers[id].sched;
        var s' := db[i+1].servers[id].sched;

        if HostNextIgnoreUnsendableReceive(s, s', ios) {
            var p := ios[0].r;
            var rp := AbstractifyUdpPacketToLSHTPacket(p);
            var g := CSingleMessage_grammar();
            assert !Demarshallable(p.msg, g) || !CSingleMessageMarshallable(parse_CSingleMessage(DemarshallFunc(p.msg, g)));

            if p.src in config.hostIds
            {
                lemma_PacketSentByServerIsMarshallable(config, db, i, p);
                assert false;
            }

            lemma_UdpEventIsAbstractable(config, db, i, ios[0]);
            lemma_CMessageGrammarValid();
            assert |p.msg| < 0x1_0000_0000_0000_0000;
            assert |g.cases| < 0x1_0000_0000;
            //assert {:fuel ValidGrammar,5} ValidGrammar(g);

            var rios := AbstractifyRawLogToIos(ios);
            assert |rios| == 1;
            assert rios[0].r == rp;

            assert s.nextActionIndex == 0;
            calc {
                s'.nextActionIndex;
                1;
                { lemma_mod_auto(LHost_NumActions()); }
                (s.nextActionIndex + 1) % LHost_NumActions();
            }
            lemma_RefinementOfUnsendablePacketHasLimitedPossibilities(p, g, rp);

            if rp.msg.InvalidMessage? {
                lemma_IgnoringInvalidMessageIsLSchedulerNext(s, s', rios);
                assert LScheduler_Next(db[i].servers[id].sched, db[i+1].servers[id].sched, AbstractifyRawLogToIos(ios));
            } else if rp.msg.Ack? {
                assert false;
            } else {
                lemma_DsConsistency(config, db, i);
                assert false;
            }
        } else {
            assert HostNextIgnoreUnsendableProcess(s, s', ios);
            lemma_IgnoringCertainMessageTypesFromNonServerIsLSchedulerNext(config, db, i, id, s, s', ios);
        }
    }

     lemma lemma_PacketsMonotonicStep(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int
        )
        requires IsValidBehavior(config, db);
        requires 0 < i < |db|;
        ensures  db[i-1].environment.sentPackets <= db[i].environment.sentPackets;
    {
        lemma_DsConsistency(config, db, i);
        lemma_DeduceTransitionFromDsBehavior(config, db, i-1);
    }

    lemma lemma_PacketsMonotonic(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        j:int
        )
        requires IsValidBehavior(config, db);
        requires 0 < i <= j < |db|;
        ensures  db[i].environment.sentPackets <= db[j].environment.sentPackets;
        decreases j-i;
    {
        if i < j {
            lemma_PacketsMonotonic(config, db, i+1, j);
        }
        /*if i < j-1 {
            lemma_PacketsMonotonic(config, db, i+1, j);
        }/ else if i == j-1 {
            lemma_PacketsMonotonicStep(config, db, j);
        }*/
    }

    lemma {:timeLimitMultiplier 2} lemma_DelegationMapComplete(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        id:EndPoint
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db| - 1;
        requires forall j :: 0 <= j < |db| ==> LEnvStepIsAbstractable(db[j].environment.nextStep);
        ensures  id in db[i].servers ==> DelegationMapComplete(db[i].servers[id].sched.host.delegationMap);
    {
        if id in db[i].servers {
            if i == 0 {
                assert DelegationMapComplete(db[i].servers[id].sched.host.delegationMap);
            } else {
                lemma_DelegationMapComplete(config, db, i - 1, id);
                var i_minus_1 := i - 1;
                assert DS_Next(db[i_minus_1], db[i_minus_1+1]);     // OBSERVE: trigger based on +1
                assert DS_Next(db[i-1], db[i]);
                if !(db[i-1].environment.nextStep.LEnvStepHostIos? && db[i-1].environment.nextStep.actor in db[i-1].servers) {
                    assert db[i].servers == db[i-1].servers;
                    assert DelegationMapComplete(db[i-1].servers[id].sched.host.delegationMap);
                } else {
                    var sched := db[i-1].servers[id].sched;
                    var sched' := db[i].servers[id].sched;
                    var ios := db[i-1].environment.nextStep.ios;
                    if id != db[i-1].environment.nextStep.actor {
                        assert db[i].servers[id] == db[i-1].servers[id];
                    } else {
                        assert LScheduler_Next(sched, sched', AbstractifyRawLogToIos(ios))
                            || HostNextIgnoreUnsendable(sched, sched', ios);
                        if HostNextIgnoreUnsendable(sched, sched', ios) {
                            assert DelegationMapComplete(db[i].servers[id].sched.host.delegationMap);
                        } else {
                            if sched.nextActionIndex == 0 {
                                assert DelegationMapComplete(db[i].servers[id].sched.host.delegationMap);
                            } else if sched.nextActionIndex == 1 {
                                assert DelegationMapComplete(db[i].servers[id].sched.host.delegationMap);
                            } else {
                                assert DelegationMapComplete(db[i].servers[id].sched.host.delegationMap);
                            }
                        }
                    }
                }
            }
        }
    }

    lemma {:timeLimitMultiplier 2} lemma_LSHTNext(
        config:ConcreteConfiguration,
        db:seq<DS_State>,
        i:int,
        ls:LSHT_State,
        ls':LSHT_State
        )
        requires IsValidBehavior(config, db);
        requires 0 <= i < |db| - 1;
        requires LEnvStepIsAbstractable(last(db).environment.nextStep);
        requires DsStateIsAbstractable(db[i]);
        requires DsStateIsAbstractable(db[i+1]);
        requires ls  == AbstractifyDsState(db[i]);
        requires ls' == AbstractifyDsState(db[i+1]);
        requires db[i].environment.nextStep.LEnvStepHostIos? ==>
                 var id := db[i].environment.nextStep.actor;
                 id in db[i].servers ==> DelegationMapComplete(db[i].servers[id].sched.host.delegationMap);
        requires forall id :: id in db[i].servers ==> id in db[i].config.hostIds;
        ensures  LSHT_Next(ls, ls');
    {
        var ds := db[i];
        var ds' := db[i+1];

        lemma_DeduceTransitionFromDsBehavior(config, db, i);

        if !ds.environment.nextStep.LEnvStepHostIos? {
            return;
        }

        lemma_LEnvironmentNextHost(db[i].environment, ls.environment, db[i+1].environment, ls'.environment);

        var id := ds.environment.nextStep.actor;
        var ios := ds.environment.nextStep.ios;
        var r_ios := AbstractifyRawLogToIos(ios);
        var replicas := ds.config.hostIds;

        assert id in ds.servers <==> id in replicas;
        
        
        lemma_AllConfigConsistent(config, db, i, ls);
        lemma_AllConfigConsistent(config, db, i+1, ls');
        if id !in ds.servers {
            //assert !exists idx :: 0 <= idx < |replicas| && replicas[idx] == id;
            assert LSHT_NextExternal(ls, ls', id, r_ios);
            assert LSHT_Next(ls, ls');
            return;
        }
        var index :| 0 <= index < |replicas| && replicas[index] == id;
        
        assert ls.environment.nextStep == LEnvStepHostIos(id, r_ios);

        assert    LScheduler_Next(ds.servers[id].sched, ds'.servers[id].sched, r_ios)
            || HostNextIgnoreUnsendable(ds.servers[id].sched, ds'.servers[id].sched, ios);
        if HostNextIgnoreUnsendable(ds.servers[id].sched, ds'.servers[id].sched, ios)
        {
            lemma_HostNextIgnoreUnsendableIsLSchedulerNext(config, db, i, id, ios);
        }
        assert LScheduler_Next(ds.servers[id].sched, ds'.servers[id].sched, r_ios);

        assert LEnvironment_Next(ds.environment, ds'.environment);
        lemma_LEnvironmentNextHost(ds.environment, ls.environment, ds'.environment, ls'.environment);
        assert LEnvironment_Next(ls.environment, ls'.environment);

        reveal_SeqIsUnique();
        forall other_idx | other_idx != index && 0 <= other_idx < |replicas|
            ensures replicas[other_idx] != replicas[index];
        {
            assert ReplicasDistinct(ls.config.hostIds, index, other_idx);
        }
        //assert RslNextOneReplica(ls, ls', index, r_ios);
        assert LSHT_NextOneHost(ls, ls', index, r_ios);
        assert LSHT_Next(ls, ls');
    }

   

    lemma {:timeLimitMultiplier 2} RefinementToLiveSHTProof(config:ConcreteConfiguration, db:seq<DS_State>) returns (sb:seq<LSHT_State>)
        requires |db| > 0;
        requires DS_Init(db[0], config);
        requires LEnvStepIsAbstractable(last(db).environment.nextStep);
        requires forall i :: 0 <= i < |db| - 1 ==> DS_Next(db[i], db[i+1]);
        ensures  |sb| == |db|;
        ensures  LSHT_Init(AbstractifyConcreteConfiguration(db[0].config), sb[0]);
        ensures  forall i :: 0 <= i < |sb| - 1 ==> LSHT_Next(sb[i], sb[i+1]);
        ensures forall i :: 0 <= i < |db| ==> DsStateIsAbstractable(db[i]) 
                                           && sb[i] == AbstractifyDsState(db[i]);
        //ensures  forall i :: 0 <= i < |db| ==> Service_Correspondence(db[i].environment.sentPackets, sb[i]);
    {
        var c := AbstractifyConcreteConfiguration(config);
        if |db| == 1 {
            lemma_DsIsAbstractable(config, db, 0);
            var ls := AbstractifyDsState(db[0]);
            sb := [ ls ];

            // Prove LSHT_MapsComplete
            calc {
                |ls.hosts|;
                |AbstractifyConcreteReplicas(db[0].servers, db[0].config.hostIds)|;
                |db[0].config.hostIds|;
                |AbstractifyEndPointsToNodeIdentities(db[0].config.hostIds)|;
                |AbstractifyToConstants(db[0].config).hostIds|;
                |ls.config.hostIds|;
            }
            var shtconcreteconfig := SHTConcreteConfiguration(
                                                        config.hostIds,
                                                        config.rootIdentity,
                                                        config.params
                                                        );
            assert SHTConcreteConfigurationIsAbstractable(shtconcreteconfig)
                && shtconcreteconfig.rootIdentity in shtconcreteconfig.hostIds
                && 0 < |shtconcreteconfig.hostIds|;
            lemma_WFSHTConcreteConfiguration(shtconcreteconfig);
            
            forall i | 0 <= i < |c.hostIds|
                ensures ls.hosts[i].host.me == ls.config.hostIds[i];
            {
                reveal_SeqIsUnique();
            }
        } else {
            lemma_DsConsistency(config, db, |db|-1);
            lemma_DeduceTransitionFromDsBehavior(config, db, |db|-2);
            lemma_DsIsAbstractable(config, db, |db|-1);
            lemma_DsIsAbstractable(config, db, |db|-2);

            var ls' := AbstractifyDsState(last(db));
            var rest := RefinementToLiveSHTProof(config, all_but_last(db));
            assert forall i :: 0 <= i < |rest| - 1 ==> LSHT_Next(rest[i], rest[i+1]);
            sb := rest + [ls'];

            // Help with sequence indexing
            forall i | 0 <= i < |db| 
                ensures DsStateIsAbstractable(db[i]);
                ensures sb[i] == AbstractifyDsState(db[i]);
            {
                lemma_DsIsAbstractable(config, db, i);
                if i < |db| - 1 {
                    assert db[i] == all_but_last(db)[i];
                    assert sb[i] == AbstractifyDsState(all_but_last(db)[i]);
                    assert sb[i] == AbstractifyDsState(db[i]);
                } else {
                    assert sb[i] == ls';
                    assert i == |db| - 1;
                    assert db[i] == last(db);
                    assert sb[i] == AbstractifyDsState(db[i]);
                }
            }

            // Prove the crucial ensures
            forall i | 0 <= i < |sb| - 1 
                ensures LSHT_Next(sb[i], sb[i+1]);
            {
                if i < |sb| - 2 {
                    // Induction hypothesis
                    assert LSHT_Next(sb[i], sb[i+1]);
                } else {
                    forall id | id in db[i].servers
                        ensures id in db[i].config.hostIds;
                    {
                        calc ==>  {
                            id in db[i].servers;
                            id in Collections__Maps2_s.mapdomain(db[i].servers);
                                { lemma_DsConsistency(config, db, i); }
                            id in Collections__Maps2_s.mapdomain(db[0].servers);
                            id in db[0].config.hostIds;
                                { lemma_DsConsistency(config, db, i); }
                            id in db[i].config.hostIds;
                        }
                    }
//                    var sht_states,_ := RefinementToSHTSequence(c, all_but_last(sb));
//                    InvHolds(c, sht_states);
                    if db[i].environment.nextStep.LEnvStepHostIos? {
                        lemma_DelegationMapComplete(config, db, i, db[i].environment.nextStep.actor);
                    }
                    lemma_LSHTNext(config, db, i, sb[i], sb[i+1]);
                    assert LSHT_Next(sb[i], sb[i+1]);
                }
            }
            //assume false;
        }
    }
    
    lemma InvHolds(config:SHTConfiguration, db:seq<SHT_State>) 
        requires |db| > 0;
        requires SHT_Init(config, db[0]);
        requires forall i :: 0 <= i < |db| - 1 ==> SHT_Next(db[i], db[i+1]);
        ensures  forall i :: 0 <= i < |db| ==> Inv(db[i]);
    {
        if |db| == 1 {
            InitInv(config, db[0]);
        } else {
            InvHolds(config, all_but_last(db));
            var d  := last(all_but_last(db));
            var d' := last(db);
            var penultimate_index := |db| - 2;
            calc {
                SHT_Next(db[penultimate_index], db[penultimate_index + 1]); // OBSERVE: +1 needed for trigger
                SHT_Next(d, d');
            }
            NextInv(d, d');
            assert Inv(d');
        }
    }

    lemma {:timeLimitMultiplier 4} RefinementToServiceStateSequence(config:SHTConfiguration, db:seq<SHT_State>) returns (sb:seq<ServiceState>, cm:seq<int>)
        requires |db| > 0;
        requires SHT_Init(config, db[0]);
        requires forall i :: 0 <= i < |db| - 1 ==> SHT_Next(db[i], db[i+1]);
        ensures  |cm| == |db|;
        ensures  cm[0] == 0;                                            // Beginnings match
        ensures  forall i :: 0 <= i < |cm| ==> 0 <= cm[i] < |sb|;       // Mappings are in bounds
        ensures  forall i :: 0 <= i < |cm| - 1 ==> cm[i] <= cm[i+1];    // Mapping is monotonic
        ensures  last(cm) == |sb| - 1;  // No extra values dangling at the end of sb
        ensures  forall i :: 0 <= i < |db| ==> MapComplete(db[i]);
        ensures  forall i :: 0 <= i < |db| ==> PacketsHaveSaneHeaders(db[i]);
        ensures  forall i :: 0 <= i < |db| ==> AllDelegationsToKnownHosts(db[i]);
        ensures  forall i :: 0 <= i < |db| ==> Refinement(db[i]) == sb[cm[i]];
        ensures  Service_Init(sb[0], MapSeqToSet(config.hostIds, x => x));
        ensures  forall i :: 0 <= i < |sb| - 1 ==> Service_Next(sb[i], sb[i+1]);
        //ensures  forall i :: 0 <= i < |db| ==> Service_Correspondence(db[i].environment.sentPackets, sb[i]);
    {
        if |db| == 1 {
            sb := [Refinement(db[0])];
            cm := [0];
        } else {
            InvHolds(config, db);
            var sb_others, cm_others := RefinementToServiceStateSequence(config, all_but_last(db));
            var d  := last(all_but_last(db));
            var d' := last(db);
            var s  := Refinement(d);
            var s' := Refinement(d');
            var penultimate_index := |db| - 2;
            calc {
                SHT_Next(db[penultimate_index], db[penultimate_index + 1]); // OBSERVE: +1 needed for trigger
                SHT_Next(d, d');
            }
            NextRefinesService(d, d');
            if Service_Next(s, s') {
                sb := sb_others + [s'];
                cm := cm_others + [|sb_others|];
                assert last(sb_others) == s;
                calc {
                    last(cm);
                    |sb_others|;
                    |sb| - 1;
                }
                assert forall i :: 0 <= i < |sb| - 1 ==> Service_Next(sb[i], sb[i+1]);
            } else {
                assert ServiceStutter(s, s');
                sb := sb_others;
                cm := cm_others + [last(cm_others)];
            }
        }
    }
    
    
    
    lemma lemma_SHTSeqAppend(sb_others:seq<SHT_State>, s:seq<SHT_State>, sb:seq<SHT_State>)
        requires |sb_others| >= 1;
        requires |s| >= 1;
        requires sb_others[|sb_others|-1] == s[0];
        requires sb == sb_others + s[1..];
        requires forall i :: 0 <= i < |sb_others| - 1 ==> SHT_Next(sb_others[i], sb_others[i+1]);
        requires forall i :: 0 <= i < |s| - 1 ==> SHT_Next(s[i], s[i+1]);
        ensures forall i :: 0 <= i < |sb| - 1 ==> SHT_Next(sb[i], sb[i+1]);
    {
        forall i | 0 <= i < |sb| - 1 
            ensures SHT_Next(sb[i], sb[i+1]) {
            if (i < |sb_others| - 1) {
                assert forall i :: 0 <= i < |sb_others| - 1 ==> SHT_Next(sb_others[i], sb_others[i+1]);
            } else if i == |sb_others| - 1 {
                var idx := |sb_others| - 1;
                var idx2 := 0;
                calc {
                    SHT_Next(s[idx2], s[idx2+1]);
                    SHT_Next(sb_others[idx], s[idx2+1]);
                    SHT_Next(sb[idx], s[idx2+1]);
                    SHT_Next(sb[idx], sb[idx+1]);
                }
            } else if i >= |sb_others| {
                assert forall i :: 0 <= i < |s| - 1 ==> SHT_Next(s[i], s[i+1]);
                var idx := i - |sb_others| + 1;
                assert SHT_Next(s[idx], s[idx + 1]);
                assert sb[i] == s[i - |sb_others| + 1];
                assert SHT_Next(sb[i], sb[i+1]);
            }
        }
    }

   lemma lemma_SHTCmSeqAppend(sb:seq<SHT_State>, cm:seq<int>, db:seq<LSHT_State>)
        requires |db| > 0;
        requires |cm| == |db|;
        requires cm[0] == 0;                                            // Beginnings match
        requires  forall i :: 0 <= i < |cm| ==> 0 <= cm[i] < |sb|;       // Mappings are in bounds
        requires  forall i :: 0 <= i < |cm| - 1 ==> cm[i] <= cm[i+1];
        requires  forall i :: 0 <= i < |db| ==> LSHT_MapsComplete(db[i]) && LSHTState_RefinementInvariant(db[i]);
        requires forall i :: 0 <= i < |db|-1 ==> LSHTState_Refine(db[i]) == sb[cm[i]] 
        requires LSHTState_Refine(db[|db|-1]) == sb[last(cm)];
        ensures forall i :: 0 <= i < |db| ==> LSHTState_Refine(db[i]) == sb[cm[i]];
    {
    }    

    lemma {:timeLimitMultiplier 2} RefinementToSHTSequence(config:SHTConfiguration, db:seq<LSHT_State>) returns (sb:seq<SHT_State>, cm:seq<int>)
        requires |db| > 0;
        requires LSHT_Init(config, db[0]);
        requires forall i :: 0 <= i < |db| - 1 ==> LSHT_Next(db[i], db[i+1]);
        ensures forall i :: 0 <= i < |db| ==> LSHTState_RefinementInvariant(db[i]);
        ensures  |cm| == |db|;
        ensures  cm[0] == 0;                                            // Beginnings match
        ensures  forall i :: 0 <= i < |cm| ==> 0 <= cm[i] < |sb|;       // Mappings are in bounds
        ensures  forall i :: 0 <= i < |cm| - 1 ==> cm[i] <= cm[i+1];    // Mapping is monotonic
        ensures  forall i :: 0 <= i < |db| ==> LSHTState_Refine(db[i]) == sb[cm[i]];
        ensures  SHT_Init(config, sb[0]);
        ensures  forall i :: 0 <= i < |sb| - 1 ==> SHT_Next(sb[i], sb[i+1]);
        ensures sb[|sb|-1] == LSHTState_Refine(db[|db|-1])
        //ensures  forall i :: 0 <= i < |db| ==> Service_Correspondence(db[i].environment.sentPackets, sb[i]);
    {
        
        if |db| == 1 {
            sb := [LSHTState_Refine(db[0])];
            cm := [0];
        } else if |db| == 2 {
            assert forall i :: 0 <= i < |db| - 1 ==> LSHT_Next(db[i], db[i+1]);
            var start_idx := 0;
            var d := db[0];
            var d' := db[1];
            calc {
                LSHT_Next(db[start_idx], db[start_idx + 1]); // OBSERVE: +1 needed for trigger
                LSHT_Next(d, d');
            }
            assert LSHT_Next(d, d');
            
            Lemma_LSHTNextImpliesSHTNext(d, d');
            var s :| IsSHTStateRefinementSequenceOf(s, LSHTState_Refine(d), LSHTState_Refine(d'));
            sb := s;
            cm := [0, |s|-1];
            assert sb[0] == LSHTState_Refine(d);
        } else {
            var sb_others, cm_others := RefinementToSHTSequence(config, all_but_last(db));
            var d  := last(all_but_last(db));
            var d' := last(db);
            var penultimate_index := |db| - 2;
            
            calc {
                LSHT_Next(db[penultimate_index], db[penultimate_index + 1]); // OBSERVE: +1 needed for trigger
                LSHT_Next(d, d');
            }

            Lemma_LSHTNextImpliesSHTNext(d, d');
            var s :| IsSHTStateRefinementSequenceOf(s, LSHTState_Refine(d), LSHTState_Refine(d'));
            assert last(sb_others) == s[0];
            
            sb := sb_others + s[1..];
            cm := cm_others + [|sb|-1];
            
            lemma_SHTSeqAppend(sb_others, s, sb);
            lemma_SHTCmSeqAppend(sb, cm, db);
                
        }
    }

    ghost method FixFinalEnvStep(config:ConcreteConfiguration, db:seq<DS_State>) returns (db':seq<DS_State>)
        requires IsValidBehavior(config, db);
        ensures  |db'| == |db|;
        ensures  DS_Init(db'[0], config);
        ensures  forall i :: 0 <= i < |db'| - 1 ==> DS_Next(db'[i], db'[i+1]);
        ensures  last(db').environment.nextStep.LEnvStepStutter?;
        ensures  forall i :: 0 <= i < |db'| - 1 ==> db'[i] == db[i];
        ensures  last(db') == last(db)[environment := last(db').environment];
        ensures  last(db').environment == last(db).environment[nextStep := LEnvStepStutter()];
        ensures  LEnvStepIsAbstractable(last(db').environment.nextStep);
    {
        var sz := |db|;
        db' := all_but_last(db) + [last(db)[environment := last(db).environment[nextStep := LEnvStepStutter()]]];
        assert |db'| == |db|;
        forall i | 0 <= i < |db'| - 1
            ensures DS_Next(db'[i], db'[i+1]);
        {
            lemma_DeduceTransitionFromDsBehavior(config, db, i);
            if i == sz - 2
            {
                assert DS_Next(db'[i], db'[i+1]);
            }
        }
        assert last(db').environment.nextStep.LEnvStepStutter?;
    }

    lemma SequenceSortedProperty(s:seq<int>, i:int, j:int)
        requires |s| > 0;
        requires forall i :: 0 <= i < |s| - 1 ==> s[i] <= s[i+1];
        requires 0 <= i <= j < |s|
        ensures  s[i] <= s[j];
        decreases j-i;
    {
        if (i == j) {
            assert s[i] <= s[j];
        } else {
            SequenceSortedProperty(s, i+1, j);
        }   
    }

    lemma ComposeMappings(lm:seq<int>, sm:seq<int>) returns (cm:seq<int>)
        requires |lm| > 0;
        requires |sm| > 0;
        requires lm[0] == sm[0] == 0;
        requires forall i :: 0 <= i < |lm| - 1 ==> lm[i] <= lm[i+1];
        requires forall i :: 0 <= i < |sm| - 1 ==> sm[i] <= sm[i+1];
        requires forall i :: 0 <= i < |lm| ==> 0 <= lm[i] < |sm|;
        ensures  |cm| == |lm|;
        ensures  cm[0] == 0;
        ensures  forall i :: 0 <= i < |cm| ==> cm[i] == sm[lm[i]];
        ensures  forall i :: 0 <= i < |cm| - 1 ==> cm[i] <= cm[i+1];
    {
        if |lm| == 1 {
            cm := [0];
        } else {
            var rest := ComposeMappings(lm[0..|lm|-1],sm);
            var last_cm := sm[lm[|lm|-1]];
            cm := rest + [last_cm];
            assert forall i :: 0 <= i < |lm[0..|lm|-1]| - 1 ==> cm[i] <= cm[i+1];
            var k := |cm|-2;
            assert 0 <= k < |lm| - 1;
            assert lm[k] <= lm[k+1];
            SequenceSortedProperty(sm, lm[|cm|-2], lm[|cm|-1]);
            assert sm[lm[|cm|-2]] <= sm[lm[|cm|-1]]; 
            assert cm[|cm|-2] <= cm[|cm|-1];
            //assert cm[i] == sm[lm[i]];
            //assert cm[
        }
    }

    lemma lemma_ServiceStateServerAddressesNeverChange(sb:seq<ServiceState>, server_addresses:set<NodeIdentity>, i:int)
        requires |sb| > 0;
        requires Service_Init(sb[0], server_addresses);
        requires forall j :: 0 <= j < |sb| - 1 ==> Service_Next(sb[j], sb[j+1]);
        requires 0 <= i < |sb|;
        ensures  sb[i].serverAddresses == server_addresses;
    {
        if i == 0 {
            return;
        }

        var j := i-1;
        assert Service_Next(sb[j], sb[j+1]);
        assert i == j+1;
        assert Service_Next(sb[i-1], sb[i]);
        assert sb[i].serverAddresses == sb[i-1].serverAddresses;
        lemma_ServiceStateServerAddressesNeverChange(sb, server_addresses, i-1);
    }

   
    lemma {:timeLimitMultiplier 2} RefinementProofForFixedBehavior(config:ConcreteConfiguration, db:seq<DS_State>) returns (sb:seq<ServiceState>, cm:seq<int>)
        requires |db| > 0;
        requires DS_Init(db[0], config);
        requires forall i :: 0 <= i < |db| - 1 ==> DS_Next(db[i], db[i+1]);
        requires last(db).environment.nextStep.LEnvStepStutter?;
        ensures  |db| == |cm|;
        ensures  cm[0] == 0;                                            // Beginnings match
        ensures  forall i :: 0 <= i < |cm| ==> 0 <= cm[i] < |sb|;       // Mappings are in bounds
        ensures  forall i :: 0 <= i < |cm| - 1 ==> cm[i] <= cm[i+1];    // Mapping is monotonic
        ensures  Service_Init(sb[0], Collections__Maps2_s.mapdomain(db[0].servers));
        ensures  forall i :: 0 <= i < |sb| - 1 ==> Service_Next(sb[i], sb[i+1]);
        ensures  forall i :: 0 <= i < |db| ==> Service_Correspondence(db[i].environment.sentPackets, sb[cm[i]]);
    {
        var sht_config := AbstractifyConcreteConfiguration(config);
        //var db' := FixFinalEnvStep(config, db);
        var lsht_states := RefinementToLiveSHTProof(config, db);
        var sht_states, map_lsht_to_sht := RefinementToSHTSequence(sht_config, lsht_states);
        var service_states, map_sht_to_service := RefinementToServiceStateSequence(sht_config, sht_states);

        sb := service_states;
        cm := ComposeMappings(map_lsht_to_sht, map_sht_to_service);
        var server_addresses := MapSeqToSet(config.hostIds, x=>x);
        assert Service_Init(sb[0], server_addresses);

        forall i | 0 <= i < |sb| - 1
            ensures Service_Next(sb[i], sb[i+1]);
        {
        }
        forall i | 0 <= i < |db|
            ensures Service_Correspondence(db[i].environment.sentPackets, sb[cm[i]]);
        {
            var concretePkts := db[i].environment.sentPackets;
            var serviceState := sb[cm[i]];
            var lsht_state := lsht_states[i];
            var sht_state := sht_states[map_lsht_to_sht[i]];
            
            forall p, reply, reserved_bytes | 
                    p in concretePkts 
                 && p.src in serviceState.serverAddresses 
                 && p.msg == MarshallServiceReply(reply, reserved_bytes)
                 && |reserved_bytes| == 8
                 ensures reply in serviceState.replies;
            {
                var lsht_packet := AbstractifyConcretePacket(p);
                lemma_ServiceStateServerAddressesNeverChange(sb, server_addresses, cm[i]);
                assert serviceState.serverAddresses == server_addresses;
                assert p.src in config.hostIds;
                lemma_PacketSentByServerIsMarshallable(config, db, i, p);
                lemma_ParseMarshallReply(p.msg, reply, lsht_packet.msg, reserved_bytes);

                assert lsht_packet.src in serviceState.serverAddresses && lsht_packet.msg.m.Reply?;
                lemma_DsIsAbstractable(config, db, i);
                assert lsht_state == AbstractifyDsState(db[i]);
                assert sht_state == LSHTState_Refine(lsht_state);
                assert serviceState == Refinement(sht_state);
                assert lsht_packet in lsht_state.environment.sentPackets;
                var sht_packet := LSHTPacketToPacket(lsht_packet);
                assert sht_packet in sht_state.network && sht_packet.msg.SingleMessage? && sht_packet.msg.m.Reply? && sht_packet.src in sht_state.hosts;
                //assume reply.client == sht_packet.dst;
                assert reply.seqno == sht_packet.msg.seqno;
                assert reply.k == sht_packet.msg.m.k_reply;
                assert reply.ov == sht_packet.msg.m.v;

                assert reply == AppReply(sht_packet.msg.seqno, sht_packet.msg.m.k_reply, sht_packet.msg.m.v);
                //assert serviceState.replies == set p | p in sht_state.network && p.msg.SingleMessage? && p.msg.m.Reply? && p.src in sht_state.hosts :: AppReply(p.src, p.msg.seqno, p.msg.m.k_reply, p.msg.m.v);
                //assert service_reply in set p | p in sht_state.network && p.msg.SingleMessage? && p.msg.m.Reply? && p.src in sht_state.hosts :: AppReply(p.src, p.msg.seqno, p.msg.m.k_reply, p.msg.m.v);
                assert reply in serviceState.replies;
                //assert reply in serviceState.replies
                //assert r in rsl.replies;
                //var service_reply := RenameToAppReply(r);
                //assert service_reply == AppReply(p.dst, seqno, reply);
                //assert service_reply in serviceState.replies;
            }
            
            forall req | req in serviceState.requests && req.AppGetRequest? 
                      ensures exists p, reserved_bytes :: p in concretePkts && p.dst in serviceState.serverAddresses 
                                                   && p.msg == MarshallServiceGetRequest(req, reserved_bytes)
                                                   && |reserved_bytes| == 8;
            {
                var h,req_index :| h in maprange(sht_state.hosts) && 0 <= req_index < |h.receivedRequests| && req == h.receivedRequests[req_index];
                var id := h.me;
                var step := lemma_FindRawAppGetRequest(config, db, i, id, req, req_index);
                
                var concrete_p := lemma_BufferedPacketFindRawPacket(config, db, step, id);
                assert concrete_p in db[step].environment.sentPackets;
                lemma_PacketsMonotonic(config,db, step, i);
                
                assert concrete_p in db[i].environment.sentPackets;
                assert concrete_p.dst in db[step].servers;
                lemma_DsConsistency(config, db, i);
                lemma_DsConsistency(config, db, step);
                assert concrete_p.dst in db[i].servers;
                assert concrete_p.dst in serviceState.serverAddresses;
                
                var sht_p := LSHTPacketToPacket(AbstractifyConcretePacket(concrete_p));
                var reserved_bytes := lemma_ParseMarshallGetRequest(concrete_p.msg, sht_p.msg);
                assert concrete_p.msg == MarshallServiceGetRequest(req, reserved_bytes);
            }
            
            forall req | req in serviceState.requests && req.AppSetRequest? 
                      ensures exists p, reserved_bytes :: p in concretePkts && p.dst in serviceState.serverAddresses 
                                                   && p.msg == MarshallServiceSetRequest(req, reserved_bytes)
                                                   && |reserved_bytes| == 8;
            {
                var h,req_index :| h in maprange(sht_state.hosts) && 0 <= req_index < |h.receivedRequests| && req == h.receivedRequests[req_index];
                var id := h.me;
                var step := lemma_FindRawAppSetRequest(config, db, i, id, req, req_index);
                
                var concrete_p := lemma_BufferedPacketFindRawPacket(config, db, step, id);
                assert concrete_p in db[step].environment.sentPackets;
                lemma_PacketsMonotonic(config,db, step, i);
                
                assert concrete_p in db[i].environment.sentPackets;
                assert concrete_p.dst in db[step].servers;
                lemma_DsConsistency(config, db, i);
                lemma_DsConsistency(config, db, step);
                assert concrete_p.dst in db[i].servers;
                assert concrete_p.dst in serviceState.serverAddresses;
                
                var sht_p := LSHTPacketToPacket(AbstractifyConcretePacket(concrete_p));
                var reserved_bytes := lemma_ParseMarshallSetRequest(concrete_p.msg, sht_p.msg);
                assert concrete_p.msg == MarshallServiceSetRequest(req, reserved_bytes);
            }
        }
    }

    lemma lemma_FixFinalEnvStep(config:ConcreteConfiguration, db:seq<DS_State>) returns (db':seq<DS_State>)
        requires IsValidBehavior(config, db);
        ensures  |db'| == |db|;
        ensures  DS_Init(db'[0], config);
        ensures  forall i :: 0 <= i < |db'| - 1 ==> DS_Next(db'[i], db'[i+1]);
        ensures  last(db').environment.nextStep.LEnvStepStutter?;
        ensures  forall i :: 0 <= i < |db'| - 1 ==> db'[i] == db[i];
        ensures  last(db') == last(db)[environment := last(db').environment];
        ensures  last(db').environment == last(db).environment[nextStep := LEnvStepStutter()];
    {
        var sz := |db|;
        db' := all_but_last(db) + [last(db)[environment := last(db).environment[nextStep := LEnvStepStutter()]]];
        assert |db'| == |db|;
        forall i | 0 <= i < |db'| - 1
            ensures DS_Next(db'[i], db'[i+1]);
        {
            lemma_DeduceTransitionFromDsBehavior(config, db, i);
            if i == sz - 2
            {
                assert DS_Next(db'[i], db'[i+1]);
            }
        }
    }

    lemma RefinementProof(config:ConcreteConfiguration, db:seq<DS_State>) returns (sb:seq<ServiceState>, cm:seq<int>)
    {
        var db' := lemma_FixFinalEnvStep(config, db);
        sb, cm := RefinementProofForFixedBehavior(config, db');
    }

    
}
