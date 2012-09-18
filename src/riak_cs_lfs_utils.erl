%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_cs_lfs_utils).

-include("riak_cs.hrl").

-export([block_count/2,
         block_keynames/3,
         block_name/3,
         block_name_to_term/1,
         block_size/0,
         max_content_len/0,
         fetch_concurrency/0,
         put_concurrency/0,
         delete_concurrency/0,
         put_fsm_buffer_size_factor/0,
         safe_block_size_from_manifest/1,
         initial_blocks/2,
         block_sequences_for_manifest/1,
         new_manifest/9,
         new_manifest/11,
         remove_write_block/2,
         remove_delete_block/2,
         sorted_blocks_remaining/1]).

%% -------------------------------------------------------------------
%% Public API
%% -------------------------------------------------------------------

%% @doc The number of blocks that this
%%      size will be broken up into
-spec block_count(non_neg_integer(), pos_integer()) -> non_neg_integer().
block_count(ContentLength, BlockSize) ->
    Quotient = ContentLength div BlockSize,
    case ContentLength rem BlockSize of
        0 ->
            Quotient;
        _ ->
            Quotient + 1
    end.

block_keynames(KeyName, UUID, BlockList) ->
    MapFun = fun(BlockSeq) ->
                     {BlockSeq, block_name(KeyName, UUID, BlockSeq)} end,
    lists:map(MapFun, BlockList).

block_name(_Key, UUID, Number) ->
    %% 16 bits & 1MB chunk size = 64GB max object size
    %% 24 bits & 1MB chunk size = 16TB max object size
    %% 32 bits & 1MB chunk size = 4PB max object size
    <<UUID/binary, Number:32>>.

block_name_to_term(<<UUID:16/binary, Number:32>>) ->
    {UUID, Number}.

%% @doc Return the configured block size
-spec block_size() -> pos_integer().
block_size() ->
    case application:get_env(riak_cs, lfs_block_size) of
        undefined ->
            ?DEFAULT_LFS_BLOCK_SIZE;
        {ok, BlockSize} ->
            BlockSize
    end.

%% @doc Return the configured block size
-spec max_content_len() -> pos_integer().
max_content_len() ->

    case application:get_env(riak_cs, max_content_length) of
        undefined ->

            ?DEFAULT_MAX_CONTENT_LENGTH;
                {ok, MaxContentLen} ->
            MaxContentLen
    end.

safe_block_size_from_manifest(?MANIFEST{block_size=BlockSize}) ->
    case BlockSize of
        undefined ->
            block_size();
        _ -> BlockSize
    end.

%% @doc A list of all of the blocks that
%%      make up the file.
-spec initial_blocks(non_neg_integer(), pos_integer()) -> list().
initial_blocks(ContentLength, BlockSize) ->
    UpperBound = block_count(ContentLength, BlockSize),
    lists:seq(0, (UpperBound - 1)).

block_sequences_for_manifest(?MANIFEST{content_length=ContentLength}=Manifest) ->
    SafeBlockSize = safe_block_size_from_manifest(Manifest),
    initial_blocks(ContentLength, SafeBlockSize).

%% @doc Return the configured file block fetch concurrency .
-spec fetch_concurrency() -> pos_integer().
fetch_concurrency() ->
    case application:get_env(riak_cs, fetch_concurrency) of
        undefined ->
            ?DEFAULT_FETCH_CONCURRENCY;
        {ok, Concurrency} ->
            Concurrency
    end.

%% @doc Return the configured file block put concurrency .
-spec put_concurrency() -> pos_integer().
put_concurrency() ->
    case application:get_env(riak_cs, put_concurrency) of
        undefined ->
            ?DEFAULT_PUT_CONCURRENCY;
        {ok, Concurrency} ->
            Concurrency
    end.

%% @doc Return the configured file block delete concurrency .
-spec delete_concurrency() -> pos_integer().
delete_concurrency() ->
    case application:get_env(riak_cs, delete_concurrency) of
        undefined ->
            ?DEFAULT_DELETE_CONCURRENCY;
        {ok, Concurrency} ->
            Concurrency
    end.

%% @doc Return the configured put fsm buffer
%% size factor
-spec put_fsm_buffer_size_factor() -> pos_integer().
put_fsm_buffer_size_factor() ->
    case application:get_env(riak_cs, put_buffer_factor) of
        undefined ->
            ?DEFAULT_PUT_BUFFER_FACTOR;
        {ok, Factor} ->
            Factor
    end.

%% @doc Initialize a new file manifest
-spec new_manifest(binary(),
                   binary(),
                   binary(),
                   non_neg_integer(),
                   binary(),
                   term(),
                   term(),
                   pos_integer(),
                   acl()) -> lfs_manifest().
new_manifest(Bucket, FileName, UUID, ContentLength, ContentType, ContentMd5, MetaData, BlockSize, Acl) ->
    new_manifest(Bucket, FileName, UUID, ContentLength, ContentType, ContentMd5, MetaData, BlockSize, Acl, [], undefined).

-spec new_manifest(binary(),
                   binary(),
                   binary(),
                   non_neg_integer(),
                   binary(),
                   term(),
                   term(),
                   pos_integer(),
                   acl(),
                   proplists:proplist(),
                   cluster_id()) -> lfs_manifest().
new_manifest(Bucket, FileName, UUID, ContentLength, ContentType, ContentMd5, MetaData, BlockSize, Acl, Props, ClusterID) ->
    Blocks = ordsets:from_list(initial_blocks(ContentLength, BlockSize)),
    ?MANIFEST{bkey={Bucket, FileName},
              uuid=UUID,
              state=writing,
              content_length=ContentLength,
              content_type=ContentType,
              content_md5=ContentMd5,
              block_size=BlockSize,
              write_blocks_remaining=Blocks,
              metadata=MetaData,
              acl=Acl,
              props=Props,
              cluster_id=ClusterID}.

%% @doc Remove a chunk from the
%%      write_blocks_remaining field of Manifest
remove_write_block(Manifest, Chunk) ->
    Remaining = Manifest?MANIFEST.write_blocks_remaining,
    Updated = ordsets:del_element(Chunk, Remaining),
    ManiState = case Updated of
                    [] ->
                        active;
                    _ ->
                        writing
                end,
    Manifest?MANIFEST{write_blocks_remaining=Updated,
                             state=ManiState,
                             last_block_written_time=os:timestamp()}.

%% @doc Remove a chunk from the `delete_blocks_remaining'
%% field of `Manifest'
remove_delete_block(Manifest, Chunk) ->
    Remaining = Manifest?MANIFEST.delete_blocks_remaining,
    Updated = ordsets:del_element(Chunk, Remaining),
    ManiState = case Updated of
                    [] ->
                        deleted;
                    _ ->
                        scheduled_delete
                end,
    Manifest?MANIFEST{delete_blocks_remaining=Updated,
                             state=ManiState,
                             last_block_deleted_time=os:timestamp()}.

sorted_blocks_remaining(?MANIFEST{write_blocks_remaining=Remaining}) ->
    lists:sort(ordsets:to_list(Remaining)).